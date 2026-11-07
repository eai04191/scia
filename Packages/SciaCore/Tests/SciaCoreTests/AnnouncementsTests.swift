import Foundation
import SciaTesting
import Synchronization
import Testing
@_spi(FailureDisplay) @testable import SciaCore

@Suite(.requestPurpose(.action))
struct AnnouncementDecodingTests {
    private func makeClient(_ transport: StubTransport) -> MastodonClient {
        MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport)
    }

    /// 読めないお知らせがあっても、ほかは読み、IDが読めれば読めなかったものとして残す。Mastodon 5.0より前の`reactions_allowed`のないお知らせは、許しているものとする。
    @Test func decodesListKeepingUnreadable() async throws {
        let list = try await makeClient(StubTransport([try .fixture("announcements")])).announcements()

        #expect(list.announcements.map(\.id) == ["8", "6"])
        #expect(list.unreadable.map(\.id) == ["7"])
        let maintenance = list.announcements[0]
        #expect(maintenance.startsAt == (try Date("2026-11-03T02:00:00Z", strategy: .iso8601)))
        #expect(maintenance.isUnread)
        #expect(maintenance.statuses == [Announcement.LinkedStatus(id: "113000000000000001", url: URL(string: "https://example.social/@admin/113000000000000001"))])
        #expect(maintenance.reactions.map(\.name) == ["blobcat", "🤔"])
        #expect(maintenance.reactions[0].customEmoji?.shortcode == "blobcat")
        #expect(maintenance.reactions[1].customEmoji == nil)
        #expect(maintenance.reactions[1].me == true)
        let old = list.announcements[1]
        #expect(!old.isUnread)
        #expect(old.reactionsAllowed)
        #expect(old.mentions.map(\.acct) == ["admin"])
    }

    /// 絵文字は1つのパスの要素として送る。キーキャップの絵文字の`#`がフラグメントにならないようにする。
    @Test func sendsReactionNameAsOnePathComponent() async throws {
        let ok = StubTransport.Response(statusCode: 200, body: Data("{}".utf8))
        let transport = StubTransport([ok, ok, ok])
        let client = makeClient(transport)

        try await client.addAnnouncementReaction("8", name: "#️⃣")
        try await client.removeAnnouncementReaction("8", name: "blobcat")
        try await client.dismissAnnouncement("8")

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "DELETE", "POST"])
        #expect(requests[0].url?.fragment() == nil)
        #expect(requests.map { $0.url?.path(percentEncoded: true) } == [
            "/api/v1/announcements/8/reactions/%23%EF%B8%8F%E2%83%A3",
            "/api/v1/announcements/8/reactions/blobcat",
            "/api/v1/announcements/8/dismiss",
        ])
    }

    /// ストリーミングのお知らせには、自分の既読とリアクションが入らない。取り下げはIDだけが届く。
    @Test func decodesStreamingEvents() throws {
        let announcement = try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"announcement","payload":"{\"id\":\"1\",\"content\":\"<p>test</p>\",\"starts_at\":null,\"ends_at\":null,\"all_day\":true,\"published_at\":\"2022-11-15T15:55:22.452Z\",\"updated_at\":\"2022-11-15T15:55:22.528Z\",\"mentions\":[],\"statuses\":[],\"tags\":[],\"emojis\":[],\"reactions\":[{\"name\":\"🤔\",\"count\":2}]}"}"#).event
        guard case .announcement(let decoded) = announcement else {
            Issue.record("お知らせとして読めませんでした: \(announcement)")
            return
        }
        #expect(decoded.read == nil)
        #expect(decoded.reactions == [AnnouncementReaction(name: "🤔", count: 2, me: nil)])

        let reaction = try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"announcement.reaction","payload":"{\"name\":\"🤔\",\"count\":1,\"announcement_id\":\"1\"}"}"#).event
        #expect(reaction == .announcementReaction(AnnouncementReactionUpdate(announcementID: "1", name: "🤔", count: 1)))

        let delete = try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"announcement.delete","payload":"1"}"#).event
        #expect(delete == .announcementDelete(announcementID: "1"))
    }
}

@MainActor
@Suite(.requestPurpose(.action))
struct AnnouncementsModelTests {
    private final class Display: AnnouncementsDisplay {
        var items: [AnnouncementListItem] = []
        var state: AnnouncementsContentState?

        func setItems(_ items: [AnnouncementListItem]) {
            self.items = items
        }

        func setContentState(_ state: AnnouncementsContentState) {
            self.state = state
        }

        var unreadMarks: [Announcement.ID] {
            items.compactMap { item in
                if case .announcement(let announcement, true) = item { announcement.id } else { nil }
            }
        }
    }

    /// 呼ばれた操作を記録する口。`held`の語で始まる操作は`hold`が開くまで結果を返さず、`failing`に入れた操作は失敗させる。
    private final class Server: Sendable {
        let lists: Mutex<[AnnouncementList]>
        let calls = Mutex<[String]>([])
        let hold = Gate()
        let held: Set<String>
        /// 次のお知らせのリストの読み込みだけを`hold`で止める。
        private let holdsNextList = Mutex(false)
        let failing: Set<String>

        init(lists: [AnnouncementList], held: Set<String> = [], failing: Set<String> = []) {
            self.lists = Mutex(lists)
            self.held = held
            self.failing = failing
        }

        var recorded: [String] { calls.withLock { $0 } }

        func holdNextList() {
            holdsNextList.withLock { $0 = true }
        }

        private func call(_ name: String) async throws {
            calls.withLock { $0.append(name) }
            if held.contains(where: { name.hasPrefix($0) }) {
                try await hold.wait()
            }
            if failing.contains(name) {
                throw MastodonAPIError(statusCode: 422, message: "Unprocessable", serverMessage: "上限に達しました")
            }
        }

        var operations: AnnouncementsModel.Operations {
            AnnouncementsModel.Operations(
                list: {
                    try await self.call("list")
                    if self.holdsNextList.withLock({ holds in defer { holds = false }; return holds }) {
                        try await self.hold.wait()
                    }
                    return self.lists.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
                },
                dismiss: { try await self.call("dismiss \($0)") },
                addReaction: { try await self.call("add \($0) \($1)") },
                removeReaction: { try await self.call("remove \($0) \($1)") }
            )
        }
    }

    private static func announcement(_ id: String, read: Bool? = false, publishedAt: TimeInterval = 0, reactions: [AnnouncementReaction] = []) -> Announcement {
        Announcement(id: id, content: "<p>\(id)</p>", publishedAt: Date(timeIntervalSince1970: 1_800_000_000 + publishedAt), read: read, reactions: reactions)
    }

    private func makeModel(_ server: Server) -> (AnnouncementsModel, Display) {
        let model = AnnouncementsModel(operations: server.operations, streamingHub: nil, tasks: TaskScope())
        let display = Display()
        model.display = display
        return (model, display)
    }

    private func loaded(_ server: Server) async throws -> (AnnouncementsModel, Display) {
        let (model, display) = makeModel(server)
        model.start()
        try await waitUntil { model.contentState == .loaded }
        return (model, display)
    }

    @Test func sortsNewestFirstAndCountsUnread() async throws {
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1", publishedAt: 0), Self.announcement("2", read: true, publishedAt: 10), Self.announcement("3", publishedAt: 20)])])
        var counts: [Int] = []
        let (model, _) = makeModel(server)
        model.onUnreadCountChange = { counts.append($0) }

        model.start()
        try await waitUntil { model.contentState == .loaded }

        #expect(model.announcements.map(\.id) == ["3", "2", "1"])
        #expect(counts == [2])
    }

    /// ストリーミングで届いた編集には自分の既読とリアクションがないので、手元の値を残す。新しく届いたものは未読にする。
    @Test func keepsOwnStateWhenEditArrives() async throws {
        let original = Self.announcement("1", read: true, reactions: [AnnouncementReaction(name: "🤔", count: 1, me: true)])
        let (model, _) = try await loaded(Server(lists: [AnnouncementList(announcements: [original])]))

        model.streamingDidChange(.event(.announcement(Self.announcement("1", read: nil, reactions: [AnnouncementReaction(name: "🤔", count: 2, me: nil)]))))
        model.streamingDidChange(.event(.announcement(Self.announcement("2", read: nil, publishedAt: 10))))

        #expect(model.announcements.map(\.id) == ["2", "1"])
        #expect(model.announcements[1].read == true)
        #expect(model.announcements[1].reactions == [AnnouncementReaction(name: "🤔", count: 2, me: true)])
        #expect(model.unreadCount == 1)
    }

    /// 数は届いた値に置き換え、0になったら消す。自分がしているものは、0で届いても1と出す。新しい絵文字は末尾に足す。
    @Test func appliesReactionCounts() async throws {
        let reactions = [AnnouncementReaction(name: "a", count: 2, me: false), AnnouncementReaction(name: "b", count: 1, me: true)]
        let (model, _) = try await loaded(Server(lists: [AnnouncementList(announcements: [Self.announcement("1", reactions: reactions)])]))

        model.streamingDidChange(.event(.announcementReaction(AnnouncementReactionUpdate(announcementID: "1", name: "a", count: 0))))
        model.streamingDidChange(.event(.announcementReaction(AnnouncementReactionUpdate(announcementID: "1", name: "b", count: 0))))
        model.streamingDidChange(.event(.announcementReaction(AnnouncementReactionUpdate(announcementID: "1", name: "c", count: 3))))

        let updated = model.announcements[0].reactions
        #expect(updated.map(\.name) == ["b", "c"])
        #expect(updated.map(\.displayedCount) == [1, 3])
    }

    @Test func removesDeletedAnnouncement() async throws {
        let (model, display) = try await loaded(Server(lists: [AnnouncementList(announcements: [Self.announcement("1"), Self.announcement("2")])]))

        model.streamingDidChange(.event(.announcementDelete(announcementID: "1")))

        #expect(display.items.map(\.id) == ["announcement:2"])
        #expect(model.unreadCount == 1)
    }

    /// 開いている間は、既読にしたお知らせにも、開いたあとに届いたお知らせにも点を残し、閉じたら消す。
    @Test func keepsUnreadMarksWhileShown() async throws {
        let (model, display) = try await loaded(Server(lists: [AnnouncementList(announcements: [Self.announcement("1"), Self.announcement("2", read: true, publishedAt: 10)])]))

        model.appear()
        model.didShow("1")
        model.streamingDidChange(.event(.announcement(Self.announcement("3", read: nil, publishedAt: 20))))

        #expect(display.unreadMarks == ["3", "1"])
        #expect(model.unreadCount == 1)
        model.disappear()
        model.appear()
        #expect(display.unreadMarks == ["3"])
    }

    /// 既読の送信に失敗したら未読に戻し、次に行が出たときに送り直す。
    @Test func retriesDismissAfterFailure() async throws {
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1")])], failing: ["dismiss 1"])
        let (model, _) = try await loaded(server)

        model.didShow("1")
        #expect(model.unreadCount == 0)
        try await waitUntil { model.unreadCount == 1 && model.runningTaskCount == 0 }
        model.didShow("1")

        try await waitUntil { server.recorded.filter { $0.hasPrefix("dismiss") }.count == 2 }
    }

    /// 押したらすぐ表示を変え、失敗したら戻して知らせる。結果を待つ間に同じリアクションを押しても送らない。
    @Test func revertsReactionOnFailure() async throws {
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1", reactions: [AnnouncementReaction(name: "a", count: 1, me: false)])])], held: ["add"], failing: ["add 1 a"])
        let (model, _) = try await loaded(server)
        var failures: [ErrorPresentation] = []
        model.onReactionFailure = { failures.append(ErrorPresentation($0)) }

        model.toggleReaction("a", on: "1")
        model.toggleReaction("a", on: "1")
        #expect(model.announcements[0].reactions == [AnnouncementReaction(name: "a", count: 2, me: true)])
        server.hold.open()
        try await waitUntil { !failures.isEmpty }

        #expect(model.announcements[0].reactions == [AnnouncementReaction(name: "a", count: 1, me: false)])
        #expect(server.recorded == ["list", "add 1 a"])
        #expect(failures.first?.message.contains("上限に達しました") == true)
    }

    /// 絵文字のシートで選んだ絵文字は末尾に足す。自分がすでにしている絵文字なら、付けたままにして送らない。
    @Test func addsChosenReaction() async throws {
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1", reactions: [AnnouncementReaction(name: "a", count: 1, me: true)])])])
        let (model, _) = try await loaded(server)
        let emoji = CustomEmoji(shortcode: "blob", url: try #require(URL(string: "https://example.social/blob.png")), staticUrl: try #require(URL(string: "https://example.social/blob_static.png")))

        model.addReaction("a", customEmoji: nil, to: "1")
        model.addReaction("blob", customEmoji: emoji, to: "1")

        #expect(model.announcements[0].reactions.map(\.name) == ["a", "blob"])
        #expect(model.announcements[0].reactions[1].customEmoji == emoji)
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(server.recorded == ["list", "add 1 blob"])
    }

    /// 結果を待っている間に読み直しても、押す前の応答で既読とリアクションを戻さない。
    @Test func keepsPendingChangesAcrossReload() async throws {
        let before = Self.announcement("1", reactions: [AnnouncementReaction(name: "a", count: 1, me: false)])
        let server = Server(lists: [AnnouncementList(announcements: [before])], held: ["dismiss", "add"])
        let (model, _) = try await loaded(server)

        model.didShow("1")
        model.toggleReaction("a", on: "1")
        await model.refresh()?.value

        #expect(model.announcements[0].read == true)
        #expect(model.announcements[0].reactions == [AnnouncementReaction(name: "a", count: 2, me: true)])
        server.hold.open()
        try await waitUntil { model.runningTaskCount == 0 }
    }

    /// 読んでいる間にストリーミングで変化が届いたら、その前に送った読み込みの応答は使わずに読み直す。
    @Test func reloadsWhenChangedWhileLoading() async throws {
        let server = Server(lists: [AnnouncementList(announcements: []), AnnouncementList(announcements: [Self.announcement("1")])], held: ["list"])
        let (model, _) = makeModel(server)

        model.start()
        try await waitUntil { server.recorded.count == 1 }
        model.streamingDidChange(.event(.announcement(Self.announcement("1", read: nil))))
        server.hold.open()
        try await waitUntil { model.contentState == .loaded }

        #expect(server.recorded == ["list", "list"])
        #expect(model.announcements.map(\.id) == ["1"])
    }

    /// 読んでいる間に既読が済んだら、既読にする前の応答を使わずに読み直す。
    @Test func reloadsWhenOperationSettlesWhileLoading() async throws {
        let before = Self.announcement("1")
        let after = Self.announcement("1", read: true)
        let server = Server(lists: [AnnouncementList(announcements: [before]), AnnouncementList(announcements: [before]), AnnouncementList(announcements: [after])])
        let (model, _) = try await loaded(server)

        server.holdNextList()
        let reload = model.refresh()
        try await waitUntil { server.recorded.count == 2 }
        model.didShow("1")
        try await waitUntil { server.recorded.contains("dismiss 1") && model.runningTaskCount == 1 }
        server.hold.open()
        await reload?.value

        #expect(server.recorded.filter { $0 == "list" }.count == 3)
        #expect(model.announcements[0].read == true)
    }

    /// 待っている間に数が届いてから失敗したら、届いた数のまま、自分がしたかだけを戻す。
    @Test func keepsReceivedCountWhenReactionFails() async throws {
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1", reactions: [AnnouncementReaction(name: "a", count: 3, me: false)])])], held: ["add"], failing: ["add 1 a"])
        let (model, _) = try await loaded(server)
        var failed = false
        model.onReactionFailure = { _ in failed = true }

        model.toggleReaction("a", on: "1")
        model.streamingDidChange(.event(.announcementReaction(AnnouncementReactionUpdate(announcementID: "1", name: "a", count: 3))))
        server.hold.open()
        try await waitUntil { failed }

        #expect(model.announcements[0].reactions == [AnnouncementReaction(name: "a", count: 3, me: false)])
    }

    /// 待っている間にお知らせ全体が届いてから失敗したら、届いた数のまま、自分がしたかだけを戻す。届いた数は押した結果を含まないため。
    @Test func keepsSnapshotCountWhenReactionFails() async throws {
        let original = AnnouncementReaction(name: "a", count: 3, me: false)
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1", reactions: [original])])], held: ["add"], failing: ["add 1 a"])
        let (model, _) = try await loaded(server)

        model.toggleReaction("a", on: "1")
        model.apply(.announcement(Self.announcement("1", read: nil, reactions: [AnnouncementReaction(name: "a", count: 3, me: nil)])))
        server.hold.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.announcements[0].reactions == [original])
    }

    /// 数が届いたあとに読み直すと、押した結果を重ねた数になる。そのあと失敗したら、重ねた分を戻す。
    @Test func revertsReappliedCountAfterReload() async throws {
        let original = AnnouncementReaction(name: "a", count: 3, me: false)
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1", reactions: [original])])], held: ["add"], failing: ["add 1 a"])
        let (model, _) = try await loaded(server)

        model.toggleReaction("a", on: "1")
        model.apply(.announcementReaction(AnnouncementReactionUpdate(announcementID: "1", name: "a", count: 3)))
        await model.refresh()?.value
        server.hold.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.announcements[0].reactions == [original])
    }

    /// 自分だけが付けていたカスタム絵文字を外すのに失敗したら、画像ごと戻す。
    @Test func restoresCustomEmojiWhenRemovalFails() async throws {
        let url = try #require(URL(string: "https://example.social/blob.png"))
        let original = AnnouncementReaction(name: "blob", count: 1, me: true, url: url, staticUrl: url)
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1", reactions: [original])])], held: ["remove"], failing: ["remove 1 blob"])
        let (model, _) = try await loaded(server)

        model.toggleReaction("blob", on: "1")
        #expect(model.announcements[0].reactions.isEmpty)
        server.hold.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.announcements[0].reactions == [original])
    }

    /// 自分だけのリアクションを外している間に0件が届き、そのあと外すのに失敗したら、自分のリアクションとして戻す。
    @Test func restoresRemovedReactionAfterZeroCount() async throws {
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1", reactions: [AnnouncementReaction(name: "a", count: 1, me: true)])])], held: ["remove"], failing: ["remove 1 a"])
        let (model, _) = try await loaded(server)

        model.toggleReaction("a", on: "1")
        model.apply(.announcementReaction(AnnouncementReactionUpdate(announcementID: "1", name: "a", count: 0)))
        server.hold.open()
        try await waitUntil { model.runningTaskCount == 0 }

        #expect(model.announcements[0].reactions.map(\.me) == [true])
        #expect(model.announcements[0].reactions.map(\.displayedCount) == [1])
    }

    /// 読めなかったお知らせも、取り下げられたら消し、読める形で届いたら差し替える。
    @Test func replacesUnreadableByStreaming() async throws {
        let server = Server(lists: [AnnouncementList(announcements: [], unreadable: [UnreadableItem(id: "1", url: nil), UnreadableItem(id: "2", url: nil)])])
        let (model, _) = try await loaded(server)

        model.apply(.announcementDelete(announcementID: "1"))
        model.apply(.announcement(Self.announcement("2", read: nil)))

        #expect(model.unreadable.isEmpty)
        #expect(model.announcements.map(\.id) == ["2"])
    }

    /// 新しいカスタム絵文字を送っている間に読み直しても、画像を失わない。
    @Test func keepsPendingCustomEmojiAcrossReload() async throws {
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1")])], held: ["add"])
        let (model, _) = try await loaded(server)
        let emoji = CustomEmoji(shortcode: "blob", url: try #require(URL(string: "https://example.social/blob.png")), staticUrl: try #require(URL(string: "https://example.social/blob_static.png")))

        model.addReaction("blob", customEmoji: emoji, to: "1")
        await model.refresh()?.value

        #expect(model.announcements[0].reactions.first?.customEmoji == emoji)
        server.hold.open()
        try await waitUntil { model.runningTaskCount == 0 }
    }

    /// つながる前に始めた読み込みの応答は、つながるまでの変化を含まないので、読み直す。
    @Test func reloadsAfterConnectingWhileLoading() async throws {
        let server = Server(lists: [AnnouncementList(announcements: []), AnnouncementList(announcements: [Self.announcement("1")])], held: ["list"])
        let (model, _) = makeModel(server)

        model.start()
        try await waitUntil { server.recorded.count == 1 }
        model.streamingDidChange(.connected)
        server.hold.open()
        try await waitUntil { model.contentState == .loaded }

        #expect(server.recorded == ["list", "list"])
        #expect(model.announcements.map(\.id) == ["1"])
    }

    /// シートで開いたときの失敗はシートに出し、自動の読み込みの失敗は出さない。読めていた行は消さない。
    @Test func showsOnlyVisibleLoadFailure() async throws {
        let server = Server(lists: [AnnouncementList(announcements: [Self.announcement("1")])], failing: ["list"])
        let (model, _) = makeModel(server)

        model.start()
        try await waitUntil { model.runningTaskCount == 0 }
        #expect(model.contentState == .loading)
        model.appear()
        try await waitUntil { model.runningTaskCount == 0 }

        guard case .failed = model.contentState else {
            Issue.record("失敗をシートに出していません: \(model.contentState)")
            return
        }
    }
}

struct AnnouncementDateTextTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        return calendar
    }()

    private static func date(_ string: String) throws -> Date {
        try Date(string, strategy: .iso8601)
    }

    private static func text(start: String?, end: String?, allDay: Bool = false, published: String = "2026-11-01T01:00:00Z") throws -> String {
        let announcement = Announcement(id: "1", content: "", startsAt: try start.map(date), endsAt: try end.map(date), allDay: allDay, publishedAt: try date(published))
        return AnnouncementDateText.text(for: announcement, now: try date("2026-11-01T03:00:00Z"), calendar: calendar)
    }

    @Test func writesPublishedDateWithoutRange() throws {
        #expect(try Self.text(start: nil, end: nil) == "11月1日 10:00")
        #expect(try Self.text(start: nil, end: nil, published: "2025-12-31T14:05:00Z") == "2025年12月31日 23:05")
    }

    @Test func omitsEndDateOnSameDay() throws {
        #expect(try Self.text(start: "2026-11-03T02:00:00Z", end: "2026-11-03T04:30:00Z") == "11月3日 11:00〜13:30")
        #expect(try Self.text(start: "2026-11-03T02:00:00Z", end: "2026-11-04T04:00:00Z") == "11月3日 11:00〜11月4日 13:00")
    }

    @Test func writesOnlyDatesForAllDay() throws {
        #expect(try Self.text(start: "2026-11-02T15:00:00Z", end: "2026-11-02T15:00:00Z", allDay: true) == "11月3日")
        #expect(try Self.text(start: "2026-12-30T15:00:00Z", end: "2027-01-02T15:00:00Z", allDay: true) == "12月31日〜2027年1月3日")
    }
}
