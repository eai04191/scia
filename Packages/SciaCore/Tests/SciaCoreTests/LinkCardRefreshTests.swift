import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// カードが付く前に受け取った投稿を、見えている間だけ間隔を空けてまとめて取り直し、届いたカードを反映することを確かめる。
struct LinkCardRefreshTests {
    private static let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))
    private static let start = Date(timeIntervalSince1970: 1_000_000)
    private static let link = #"<p><a href="https://news.example/articles/1">news.example/articles/1</a></p>"#

    private static func status(_ id: String, createdAt: Date = start, content: String = link, card: PreviewCard? = nil) -> Status {
        Status(id: id, createdAt: createdAt, account: account, content: content, spoilerText: "", url: nil, card: card)
    }

    private static func version(_ id: String, editedAt: Date? = nil) -> LinkCardRefreshSchedule.Version {
        LinkCardRefreshSchedule.Version(statusID: id, editedAt: editedAt)
    }

    private static func edited(_ id: String, createdAt: Date = start, editedAt: Date) -> Status {
        Status(id: id, createdAt: createdAt, account: account, content: link, spoilerText: "", url: nil, editedAt: editedAt)
    }

    private static func card() throws -> PreviewCard {
        PreviewCard(url: try #require(URL(string: "https://news.example/articles/1")), title: "見出し", description: "", type: .link, providerName: "News")
    }

    // MARK: - 予定

    /// 最初は3秒後に、そのあとは10秒ごとに取り直し、初めて見てから180秒を過ぎた取り直しで諦める。
    @Test func refreshesEveryIntervalUntilGivingUp() throws {
        var schedule = LinkCardRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)
        let visible: Set = [Self.version("1")]

        #expect(schedule.due(now: Self.start.addingTimeInterval(2), visible: visible, limit: 20).isEmpty)
        #expect(schedule.nextDate(visible: visible) == Self.start.addingTimeInterval(3))
        #expect(schedule.due(now: Self.start.addingTimeInterval(3), visible: visible, limit: 20).map(\.version.statusID) == ["1"])
        #expect(schedule.nextDate(visible: visible) == Self.start.addingTimeInterval(13))
        #expect(schedule.due(now: Self.start.addingTimeInterval(12), visible: visible, limit: 20).isEmpty)
        var last: LinkCardRefreshSchedule.Attempt?
        var date = Self.start.addingTimeInterval(13)
        while let next = schedule.nextDate(visible: visible), next <= Self.start.addingTimeInterval(500) {
            #expect(next == date)
            let attempt = try #require(schedule.due(now: next, visible: visible, limit: 20).first)
            #expect(attempt.isFinal == (next >= Self.start.addingTimeInterval(180)))
            last = attempt
            date = next.addingTimeInterval(10)
        }
        #expect(last?.isFinal == true)
        #expect(last?.count == 19)
        #expect(schedule.due(now: Self.start.addingTimeInterval(500), visible: visible, limit: 20).isEmpty)
    }

    /// 見えない間は取り直さず、また見えたら、すぐに取り直す。
    @Test func waitsWhileHiddenAndCatchesUpOnce() {
        var schedule = LinkCardRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)

        #expect(schedule.due(now: Self.start.addingTimeInterval(20), visible: [], limit: 20).isEmpty)
        #expect(schedule.nextDate(visible: []) == nil)
        #expect(schedule.due(now: Self.start.addingTimeInterval(20), visible: [Self.version("1")], limit: 20).map(\.version.statusID) == ["1"])
        #expect(schedule.nextDate(visible: [Self.version("1")]) == Self.start.addingTimeInterval(30))
    }

    /// 見えないまま諦める時刻を過ぎても、また見えたら1回だけ取り直す。
    @Test func refreshesOnceWhenSeenAgainAfterGivingUpTime() {
        var schedule = LinkCardRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)

        let due = schedule.due(now: Self.start.addingTimeInterval(300), visible: [Self.version("1")], limit: 20)

        #expect(due.map(\.version.statusID) == ["1"])
        #expect(due.first?.isFinal == true)
        #expect(schedule.nextDate(visible: [Self.version("1")]) == nil)
    }

    /// 投稿がいくつあっても、取り直しは10秒に1回にまとめる。
    @Test func batchesStatusesIntoOneRequestPerInterval() {
        var schedule = LinkCardRefreshSchedule()
        schedule.note([Self.status("a")], now: Self.start)
        schedule.note([Self.status("b")], now: Self.start.addingTimeInterval(5))
        let visible: Set = [Self.version("a"), Self.version("b")]

        #expect(schedule.due(now: Self.start.addingTimeInterval(3), visible: visible, limit: 20).map(\.version.statusID) == ["a"])
        #expect(schedule.due(now: Self.start.addingTimeInterval(8), visible: visible, limit: 20).isEmpty)
        #expect(schedule.nextDate(visible: visible) == Self.start.addingTimeInterval(13))
        #expect(schedule.due(now: Self.start.addingTimeInterval(13), visible: visible, limit: 20).map(\.version.statusID) == ["b", "a"])
    }

    /// サーバーのカードがある投稿と、リンクのない投稿と、カードを付け終えたとみなせる古い投稿は、予定に入れない。
    @Test func ignoresStatusesThatNeedNoRefresh() throws {
        var schedule = LinkCardRefreshSchedule()
        schedule.note([
            Self.status("carded", card: try Self.card()),
            Self.status("plain", content: "<p>リンクのない本文</p>"),
            Self.status("old", createdAt: Self.start.addingTimeInterval(-601)),
        ], now: Self.start)

        #expect(schedule.nextDate(visible: [Self.version("carded"), Self.version("plain"), Self.version("old")]) == nil)
    }

    /// Mastodonは編集でカードを消して取りに行き直すため、取り直し終えた投稿も、編集されたら予定を立て直す。
    @Test func editGetsNewSchedule() {
        var schedule = LinkCardRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)
        schedule.finish([Self.version("1")])
        let editedAt = Self.start.addingTimeInterval(100)
        schedule.note([Self.edited("1", editedAt: editedAt)], now: editedAt)

        #expect(schedule.nextDate(visible: [Self.version("1", editedAt: editedAt)]) == editedAt.addingTimeInterval(3))
    }

    /// 作られてから時間の経った投稿でも、編集したばかりなら取り直す。
    @Test func recentEditOfOldPostIsRefreshed() {
        var schedule = LinkCardRefreshSchedule()
        let editedAt = Self.start.addingTimeInterval(-10)
        schedule.note([Self.edited("1", createdAt: Self.start.addingTimeInterval(-3_600), editedAt: editedAt)], now: Self.start)

        #expect(schedule.nextDate(visible: [Self.version("1", editedAt: editedAt)]) == Self.start.addingTimeInterval(3))
    }

    @Test func finishedStatusIsNotNotedAgain() {
        var schedule = LinkCardRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)
        schedule.finish([Self.version("1")])
        schedule.note([Self.status("1")], now: Self.start.addingTimeInterval(1))

        #expect(schedule.nextDate(visible: [Self.version("1")]) == nil)
    }

    /// 1回で送れる件数を超えたら、長く取り直していない投稿から送る。
    @Test func rotatesStatusesBeyondLimit() {
        var schedule = LinkCardRefreshSchedule()
        schedule.note([Self.status("b")], now: Self.start)
        schedule.note([Self.status("a")], now: Self.start.addingTimeInterval(1))
        let visible: Set = [Self.version("a"), Self.version("b")]

        #expect(schedule.due(now: Self.start.addingTimeInterval(10), visible: visible, limit: 1).map(\.version.statusID) == ["b"])
        #expect(schedule.due(now: Self.start.addingTimeInterval(20), visible: visible, limit: 1).map(\.version.statusID) == ["a"])
        #expect(schedule.due(now: Self.start.addingTimeInterval(30), visible: visible, limit: 1).map(\.version.statusID) == ["b"])
    }

    // MARK: - 取り直し

    /// 2回目でカードが届いたら反映し、それより後は取り直さない。
    @MainActor
    @Test func appliesCardWhenItArrives() async throws {
        let clock = FakeClock(now: Self.start)
        let card = try Self.card()
        let fetches = Recorder<[Status.ID]>()
        var applied: [Status] = []
        let refresher = LinkCardRefresher(
            fetch: { ids in
                let count = await fetches.append(ids)
                return ids.map { Self.status($0, card: count >= 2 ? card : nil) }
            },
            apply: { applied.append($0) },
            now: { clock.now },
            sleep: { await clock.advance($0) }
        )
        let owner = NSObject()

        refresher.setVisible([Self.status("1")], from: owner)
        await refresher.waitUntilIdle()

        #expect(await fetches.values == [["1"], ["1"]])
        #expect(applied.map(\.id) == ["1"])
        #expect(applied.first?.card == card)
        #expect(clock.now == Self.start.addingTimeInterval(13))
    }

    /// サーバーが返さなかった投稿は、消えたものとして取り直さない。
    @MainActor
    @Test func stopsRefreshingStatusesTheServerDoesNotReturn() async {
        let clock = FakeClock(now: Self.start)
        let fetches = Recorder<[Status.ID]>()
        let refresher = LinkCardRefresher(
            fetch: { ids in
                await fetches.append(ids)
                return []
            },
            apply: { _ in },
            now: { clock.now },
            sleep: { await clock.advance($0) }
        )
        let owner = NSObject()

        refresher.setVisible([Self.status("1")], from: owner)
        await refresher.waitUntilIdle()

        #expect(await fetches.values == [["1"]])
    }

    /// ログアウトなどでセッションを止めたら、取り直している途中でも止め、あとから見えた投稿も取り直さない。前のアカウントのトークンで送り続けないため。
    @MainActor
    @Test func stopsRefreshingWhenStopped() async throws {
        let clock = FakeClock(now: Self.start)
        let fetches = Recorder<[Status.ID]>()
        let gate = Gate()
        let refresher = LinkCardRefresher(
            fetch: { ids in
                await fetches.append(ids)
                try await gate.wait()
                return ids.map { Self.status($0) }
            },
            apply: { _ in },
            now: { clock.now },
            sleep: { await clock.advance($0) }
        )
        let owner = NSObject()

        refresher.setVisible([Self.status("1")], from: owner)
        try await waitUntil { gate.waiterCount == 1 }
        refresher.stop()
        // 止めずに取り直しを続けたら、届いた結果のあとも予定どおりに取り直す。
        gate.open()
        await refresher.waitUntilIdle()
        refresher.setVisible([Self.status("2")], from: owner)
        await refresher.waitUntilIdle()

        #expect(await fetches.values == [["1"]])
    }

    /// 画面から消えたら、次に見えるまで取り直さない。
    @MainActor
    @Test func doesNotRefreshAfterSourceHides() async {
        let clock = FakeClock(now: Self.start)
        let fetches = Recorder<[Status.ID]>()
        let refresher = LinkCardRefresher(
            fetch: { ids in
                await fetches.append(ids)
                return ids.map { Self.status($0) }
            },
            apply: { _ in },
            now: { clock.now },
            sleep: { await clock.advance($0) }
        )
        let owner = NSObject()

        refresher.setVisible([Self.status("1")], from: owner)
        refresher.setVisible([], from: owner)
        await refresher.waitUntilIdle()

        #expect(await fetches.values.isEmpty)
    }

    /// サーバーがまとめて読めなければ、そのセッションでは取り直さない。
    @MainActor
    @Test func stopsWhenServerCannotReadMultipleStatuses() async {
        let clock = FakeClock(now: Self.start)
        let fetches = Recorder<[Status.ID]>()
        let refresher = LinkCardRefresher(
            fetch: { ids in
                await fetches.append(ids)
                throw FeatureUnavailable(feature: .multipleStatuses)
            },
            apply: { _ in },
            now: { clock.now },
            sleep: { await clock.advance($0) }
        )
        let owner = NSObject()

        refresher.setVisible([Self.status("1")], from: owner)
        await refresher.waitUntilIdle()
        refresher.setVisible([Self.status("2")], from: owner)
        await refresher.waitUntilIdle()

        #expect(await fetches.values == [["1"]])
    }

    /// スクロールから始めても、取り直しは自動の通信として送り、レート制限で止めている間は控えられるようにする。
    @MainActor
    @Test func refreshesAsAutomaticRequest() async {
        let clock = FakeClock(now: Self.start)
        let origins = Recorder<RequestOrigin>()
        let refresher = LinkCardRefresher(
            fetch: { ids in
                await origins.append(RequestOrigin.current)
                return []
            },
            apply: { _ in },
            now: { clock.now },
            sleep: { await clock.advance($0) }
        )
        let owner = NSObject()

        refresher.setVisible([Self.status("1")], from: owner)
        await refresher.waitUntilIdle()

        #expect(await origins.values == [.automatic])
    }

    @Test func adoptsCardOfSameVersion() throws {
        let card = try Self.card()
        let shown = Self.status("1")

        #expect(shown.adoptingCard(of: Self.status("1", card: card)).card == card)
    }

    /// 取り直している間に編集が届いていたら、取り直したのは編集の前の版なので、そのカードは付けない。
    @Test func ignoresCardOfOlderVersion() throws {
        let card = try Self.card()
        let edited = Status(
            id: "1",
            createdAt: Self.start,
            account: Self.account,
            content: "<p>リンクを消した</p>",
            spoilerText: "",
            url: nil,
            editedAt: Self.start.addingTimeInterval(5)
        )

        #expect(edited.adoptingCard(of: Self.status("1", card: card)).card == nil)
    }

    @Test func clientRequestsStatusesByID() async throws {
        let url = try #require(Bundle.module.url(forResource: "status", withExtension: "json", subdirectory: "Fixtures"))
        let body = "[" + (try String(contentsOf: url, encoding: .utf8)) + "]"
        let transport = StubTransport([.json(body, statusCode: 200)])
        let client = MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport
        )

        let statuses = try await client.statuses(["113000000000000001", "2"])

        #expect(statuses.map(\.id) == ["113000000000000001"])
        let requested = try #require(await transport.requests.first?.url)
        #expect(requested.path() == "/api/v1/statuses")
        #expect(URLComponents(url: requested, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "id[]", value: "113000000000000001"),
            URLQueryItem(name: "id[]", value: "2"),
        ])
    }
}

/// 待つ代わりに時刻を進める時計。
@MainActor
private final class FakeClock {
    private(set) var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        now = now.addingTimeInterval(Double(seconds) + Double(attoseconds) / 1e18)
    }
}

private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []

    @discardableResult
    func append(_ value: Value) -> Int {
        values.append(value)
        return values.count
    }
}
