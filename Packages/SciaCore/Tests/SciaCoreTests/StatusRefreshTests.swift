import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// サーバーが仕上げ終える前に受け取った投稿を、見えている間だけ間隔を空けてまとめて取り直し、仕上がった中身を反映することを確かめる。
struct StatusRefreshTests {
    private static let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))
    private static let start = Date(timeIntervalSince1970: 1_000_000)
    private static let link = #"<p><a href="https://news.example/articles/1">news.example/articles/1</a></p>"#

    private static func status(_ id: String, createdAt: Date = start, content: String = link, card: PreviewCard? = nil) -> Status {
        Status(id: id, createdAt: createdAt, account: account, content: content, spoilerText: "", url: nil, card: card)
    }

    private static func version(_ id: String, editedAt: Date? = nil) -> StatusRefreshSchedule.Version {
        StatusRefreshSchedule.Version(statusID: id, editedAt: editedAt)
    }

    private static func edited(_ id: String, createdAt: Date = start, editedAt: Date) -> Status {
        Status(id: id, createdAt: createdAt, account: account, content: link, spoilerText: "", url: nil, editedAt: editedAt)
    }

    private static func card() throws -> PreviewCard {
        PreviewCard(url: try #require(URL(string: "https://news.example/articles/1")), title: "見出し", description: "", type: .link, providerName: "News")
    }

    private static func quoting(_ id: String, state: String, nestedState: String? = nil) -> Status {
        let nested = nestedState.map { Quote(state: $0, quotedStatusID: "nested") }
        let quoted = Status(id: "quoted-\(id)", createdAt: start, account: account, content: "<p>引用元</p>", spoilerText: "", url: nil, quote: nested)
        return Status(
            id: id,
            createdAt: start,
            account: account,
            content: "<p>引用した投稿</p>",
            spoilerText: "",
            url: nil,
            quote: Quote(state: state, quotedStatus: state == "accepted" ? quoted : nil, quotedStatusID: "quoted-\(id)")
        )
    }

    // MARK: - 理由

    /// 引用か、引用元の中の引用が承認待ちなら、取り直す。Mastodonは、引用の承認を確かめ終える前に配信することがあり、
    /// 確かめ終えたことは、その投稿の作者のフォロワーにしかストリーミングで流さないため。
    @Test func pendingQuoteNeedsRefresh() {
        #expect(StatusRefreshNeeds(Self.quoting("1", state: "pending")) == .pendingQuote)
        #expect(StatusRefreshNeeds(Self.quoting("2", state: "accepted", nestedState: "pending")) == .pendingQuote)
        #expect(StatusRefreshNeeds(Self.quoting("3", state: "accepted", nestedState: "accepted")).isEmpty)
        #expect(StatusRefreshNeeds(Self.quoting("4", state: "revoked")).isEmpty)
    }

    // MARK: - 予定

    /// 最初は3秒後に、そのあとは10秒ごとに取り直し、初めて見てから180秒を過ぎた取り直しで諦める。
    @Test func refreshesEveryIntervalUntilGivingUp() throws {
        var schedule = StatusRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)
        let visible: Set = [Self.version("1")]

        #expect(schedule.due(now: Self.start.addingTimeInterval(2), visible: visible, limit: 20).isEmpty)
        #expect(schedule.nextDate(visible: visible) == Self.start.addingTimeInterval(3))
        #expect(schedule.due(now: Self.start.addingTimeInterval(3), visible: visible, limit: 20).map(\.version.statusID) == ["1"])
        #expect(schedule.nextDate(visible: visible) == Self.start.addingTimeInterval(13))
        #expect(schedule.due(now: Self.start.addingTimeInterval(12), visible: visible, limit: 20).isEmpty)
        var last: StatusRefreshSchedule.Attempt?
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
        var schedule = StatusRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)

        #expect(schedule.due(now: Self.start.addingTimeInterval(20), visible: [], limit: 20).isEmpty)
        #expect(schedule.nextDate(visible: []) == nil)
        #expect(schedule.due(now: Self.start.addingTimeInterval(20), visible: [Self.version("1")], limit: 20).map(\.version.statusID) == ["1"])
        #expect(schedule.nextDate(visible: [Self.version("1")]) == Self.start.addingTimeInterval(30))
    }

    /// 見えないまま諦める時刻を過ぎても、また見えたら1回だけ取り直す。
    @Test func refreshesOnceWhenSeenAgainAfterGivingUpTime() {
        var schedule = StatusRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)

        let due = schedule.due(now: Self.start.addingTimeInterval(300), visible: [Self.version("1")], limit: 20)

        #expect(due.map(\.version.statusID) == ["1"])
        #expect(due.first?.isFinal == true)
        #expect(schedule.nextDate(visible: [Self.version("1")]) == nil)
    }

    /// 初めて見てから長く見えないままでも、予定を忘れず、また見えたら1回だけ取り直す。
    /// 見かけたあと画面を離れている間にサーバーがカードを付けても、戻ったときに出すため。
    @Test func refreshesOnceWhenSeenAgainLongAfterFirstSeen() {
        var schedule = StatusRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)

        let due = schedule.due(now: Self.start.addingTimeInterval(900), visible: [Self.version("1")], limit: 20)

        #expect(due.map(\.version.statusID) == ["1"])
        #expect(due.first?.isFinal == true)
        #expect(schedule.nextDate(visible: [Self.version("1")]) == nil)
    }

    /// 作られてから時間の経った投稿を初めて見たら、待たずに1回だけ取り直す。
    /// 若いうちに受け取って見えないままだった投稿は、サーバーがカードを付けたあとも、受け取った時点の中身のままのため。
    @Test func oldStatusIsRefreshedOnceRightAway() {
        var schedule = StatusRefreshSchedule()
        schedule.note([Self.status("old", createdAt: Self.start.addingTimeInterval(-601))], now: Self.start)
        let visible: Set = [Self.version("old")]

        #expect(schedule.nextDate(visible: visible) == Self.start)
        let due = schedule.due(now: Self.start, visible: visible, limit: 20)
        #expect(due.map(\.version.statusID) == ["old"])
        #expect(due.first?.isFinal == true)
        #expect(schedule.nextDate(visible: visible) == nil)
    }

    /// 投稿がいくつあっても、取り直しは10秒に1回にまとめる。
    @Test func batchesStatusesIntoOneRequestPerInterval() {
        var schedule = StatusRefreshSchedule()
        schedule.note([Self.status("a")], now: Self.start)
        schedule.note([Self.status("b")], now: Self.start.addingTimeInterval(5))
        let visible: Set = [Self.version("a"), Self.version("b")]

        #expect(schedule.due(now: Self.start.addingTimeInterval(3), visible: visible, limit: 20).map(\.version.statusID) == ["a"])
        #expect(schedule.due(now: Self.start.addingTimeInterval(8), visible: visible, limit: 20).isEmpty)
        #expect(schedule.nextDate(visible: visible) == Self.start.addingTimeInterval(13))
        #expect(schedule.due(now: Self.start.addingTimeInterval(13), visible: visible, limit: 20).map(\.version.statusID) == ["b", "a"])
    }

    /// サーバーのカードがある投稿と、リンクのない投稿は、予定に入れない。
    @Test func ignoresStatusesThatNeedNoRefresh() throws {
        var schedule = StatusRefreshSchedule()
        schedule.note([
            Self.status("carded", card: try Self.card()),
            Self.status("plain", content: "<p>リンクのない本文</p>"),
        ], now: Self.start)

        #expect(schedule.nextDate(visible: [Self.version("carded"), Self.version("plain")]) == nil)
    }

    /// Mastodonは編集でカードを消して取りに行き直すため、取り直し終えた投稿も、編集されたら予定を立て直す。
    @Test func editGetsNewSchedule() {
        var schedule = StatusRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)
        schedule.finish([Self.version("1")])
        let editedAt = Self.start.addingTimeInterval(100)
        schedule.note([Self.edited("1", editedAt: editedAt)], now: editedAt)

        #expect(schedule.nextDate(visible: [Self.version("1", editedAt: editedAt)]) == editedAt.addingTimeInterval(3))
    }

    /// 作られてから時間の経った投稿でも、編集したばかりなら取り直す。
    @Test func recentEditOfOldPostIsRefreshed() {
        var schedule = StatusRefreshSchedule()
        let editedAt = Self.start.addingTimeInterval(-10)
        schedule.note([Self.edited("1", createdAt: Self.start.addingTimeInterval(-3_600), editedAt: editedAt)], now: Self.start)

        #expect(schedule.nextDate(visible: [Self.version("1", editedAt: editedAt)]) == Self.start.addingTimeInterval(3))
    }

    @Test func finishedStatusIsNotNotedAgain() {
        var schedule = StatusRefreshSchedule()
        schedule.note([Self.status("1")], now: Self.start)
        schedule.finish([Self.version("1")])
        schedule.note([Self.status("1")], now: Self.start.addingTimeInterval(1))

        #expect(schedule.nextDate(visible: [Self.version("1")]) == nil)
    }

    /// 1回で送れる件数を超えたら、長く取り直していない投稿から送る。
    @Test func rotatesStatusesBeyondLimit() {
        var schedule = StatusRefreshSchedule()
        schedule.note([Self.status("b")], now: Self.start)
        schedule.note([Self.status("a")], now: Self.start.addingTimeInterval(1))
        let visible: Set = [Self.version("a"), Self.version("b")]

        #expect(schedule.due(now: Self.start.addingTimeInterval(10), visible: visible, limit: 1).map(\.version.statusID) == ["b"])
        #expect(schedule.due(now: Self.start.addingTimeInterval(20), visible: visible, limit: 1).map(\.version.statusID) == ["a"])
        #expect(schedule.due(now: Self.start.addingTimeInterval(30), visible: visible, limit: 1).map(\.version.statusID) == ["b"])
    }

    // MARK: - 取り直し

    /// 取り直すたびに反映し、2回目でカードが届いたら、それより後は取り直さない。
    @MainActor
    @Test func appliesCardWhenItArrives() async throws {
        let clock = FakeClock(now: Self.start)
        let card = try Self.card()
        let fetches = Recorder<[Status.ID]>()
        var applied: [Status] = []
        let refresher = StatusRefresher(
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
        #expect(applied.map(\.id) == ["1", "1"])
        #expect(applied.last?.card == card)
        #expect(clock.now == Self.start.addingTimeInterval(13))
    }

    /// サーバーが返さなかった投稿は、消えたものとして取り直さない。
    @MainActor
    @Test func stopsRefreshingStatusesTheServerDoesNotReturn() async {
        let clock = FakeClock(now: Self.start)
        let fetches = Recorder<[Status.ID]>()
        let refresher = StatusRefresher(
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
        let refresher = StatusRefresher(
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
        let refresher = StatusRefresher(
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
        let refresher = StatusRefresher(
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
        let origins = Recorder<RequestPurpose?>()
        let refresher = StatusRefresher(
            fetch: { ids in
                await origins.append(RequestPurpose.current)
                return []
            },
            apply: { _ in },
            now: { clock.now },
            sleep: { await clock.advance($0) }
        )
        let owner = NSObject()

        refresher.setVisible([Self.status("1")], from: owner)
        await refresher.waitUntilIdle()

        #expect(await origins.values == [.display])
    }

    /// 承認待ちの引用は、取り直した引用に差し替える。
    @Test func adoptsSettledQuote() {
        let refetched = Self.quoting("1", state: "accepted", nestedState: "accepted")

        #expect(Self.quoting("1", state: "pending").adoptingRefreshed(of: refetched).quote == refetched.quote)
        #expect(Self.quoting("1", state: "accepted", nestedState: "pending").adoptingRefreshed(of: refetched).quote == refetched.quote)
    }

    /// 引用元の中の引用だけが承認待ちなら、引用元は手元のまま残し、中の引用だけを差し替える。
    /// 取り直している間に囲みから行ったお気に入りを、取り直した中身で戻さないため。
    @MainActor
    @Test func nestedQuoteKeepsActionsOnQuotedStatus() throws {
        let shown = Self.quoting("1", state: "accepted", nestedState: "pending")
        let favourited = TimelineStore.updatingQuoted("quoted-1", in: shown) { $0.settingFavourited(true) }
        let refetched = Self.quoting("1", state: "accepted", nestedState: "accepted")

        let adopted = try #require(favourited.adoptingRefreshed(of: refetched).quote?.quotedStatus)

        #expect(adopted.quote?.state == .accepted)
        #expect(adopted.favourited)
    }

    /// 承認待ちでない引用は、取り直した引用に差し替えない。取り直している間に囲みから行ったお気に入りなどを、取り直した中身で戻さないため。
    @Test func keepsQuoteThatWasNotPending() {
        let shown = Self.quoting("1", state: "accepted", nestedState: "accepted")
        let refetched = Self.quoting("1", state: "revoked")

        #expect(shown.adoptingRefreshed(of: refetched).quote == shown.quote)
    }

    /// 承認待ちの引用が承認されたら反映し、それより後は取り直さない。
    @MainActor
    @Test func appliesQuoteWhenItIsAccepted() async {
        let clock = FakeClock(now: Self.start)
        let fetches = Recorder<[Status.ID]>()
        var applied: [Status] = []
        let refresher = StatusRefresher(
            fetch: { ids in
                let count = await fetches.append(ids)
                return ids.map { Self.quoting($0, state: count >= 2 ? "accepted" : "pending") }
            },
            apply: { applied.append($0) },
            now: { clock.now },
            sleep: { await clock.advance($0) }
        )
        let owner = NSObject()

        refresher.setVisible([Self.quoting("1", state: "pending")], from: owner)
        await refresher.waitUntilIdle()

        #expect(await fetches.values == [["1"], ["1"]])
        #expect(applied.last?.quote?.state == .accepted)
    }

    @Test func adoptsCardOfSameVersion() throws {
        let card = try Self.card()
        let shown = Self.status("1")

        #expect(shown.adoptingRefreshed(of: Self.status("1", card: card)).card == card)
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

        #expect(edited.adoptingRefreshed(of: Self.status("1", card: card)).card == nil)
    }

    @Test(.requestPurpose(.action)) func clientRequestsStatusesByID() async throws {
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
