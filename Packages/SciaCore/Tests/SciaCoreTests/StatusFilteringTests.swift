import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

private let now = Date(timeIntervalSince1970: 1_000_000)
private let me = Account(id: "1", username: "me", acct: "me", displayName: "Me", avatar: URL(string: "https://example.social/me.png"))
private let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/bob.png"))

private func filter(
    _ title: String,
    _ action: FilterResult.Action,
    context: [FilterResult.Context] = [.home, .notifications, .account],
    expiresAt: Date? = nil
) -> FilterResult {
    FilterResult(filter: FilterResult.Filter(id: title, title: title, context: context, filterAction: action, expiresAt: expiresAt), keywordMatches: [title])
}

private func status(_ id: String, by account: Account = bob, filtered: [FilterResult] = [], reblog: Status? = nil) -> Status {
    Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: account, content: "<p>\(id)</p>", spoilerText: "", url: nil, filtered: filtered, reblog: reblog)
}

struct StatusFilteringTests {
    private let home = StatusFiltering(context: .home, myAccountID: me.id)

    @Test func hidesWhenAnyFilterHides() {
        let verdict = home.verdict(for: status("10", filtered: [filter("a", .warn), filter("b", .hide)]), now: now)
        #expect(verdict.isHidden)
    }

    /// ブックマークやお気に入りのタイムラインでは、「隠す」に一致しても隠さず、警告で折りたたむ。公式のWebクライアントの`warnInsteadOfHide`と同じ。
    @Test func warnsInsteadOfHidingWhenAsked() {
        let saved = StatusFiltering(context: .home, myAccountID: me.id, hidesMatches: false)
        let verdict = saved.verdict(for: status("10", filtered: [filter("a", .warn), filter("b", .hide), filter("c", .blur)]), now: now)
        #expect(verdict == FilterVerdict(isHidden: false, warningTitles: ["a", "b"], mediaTitles: ["c"], ownMatchTitles: []))
    }

    @Test func warnsWithTitlesAndBlursMediaSeparately() {
        let verdict = home.verdict(for: status("10", filtered: [filter("a", .warn), filter("b", .blur), filter("a", .warn)]), now: now)
        #expect(verdict == FilterVerdict(isHidden: false, warningTitles: ["a"], mediaTitles: ["b"], ownMatchTitles: []))
    }

    /// ドキュメントは、知らない扱いを警告として扱うよう求めている。
    @Test func treatsUnknownActionAsWarning() {
        let verdict = home.verdict(for: status("10", filtered: [filter("a", .other("future"))]), now: now)
        #expect(verdict.warningTitles == ["a"])
    }

    @Test func ignoresFiltersForOtherContexts() {
        let verdict = home.verdict(for: status("10", filtered: [filter("a", .hide, context: [.public])]), now: now)
        #expect(verdict == .none)
    }

    @Test func ignoresExpiredFilters() {
        let expired = filter("a", .hide, expiresAt: now.addingTimeInterval(-1))
        let active = filter("b", .warn, expiresAt: now.addingTimeInterval(60))
        let verdict = home.verdict(for: status("10", filtered: [expired, active]), now: now)
        #expect(verdict == FilterVerdict(isHidden: false, warningTitles: ["b"], mediaTitles: [], ownMatchTitles: []))
    }

    /// 公式のWebクライアントと同じく、自分の投稿には当てない。自分のブーストでも、元の投稿が他人のものなら当てる。
    @Test func skipsOwnStatusesButNotOwnBoostsOfOthers() {
        #expect(!home.verdict(for: status("10", by: me, filtered: [filter("a", .hide)]), now: now).isHidden)

        let original = status("10", filtered: [filter("a", .hide)])
        #expect(home.verdict(for: status("20", by: me, filtered: [filter("a", .hide)], reblog: original), now: now).isHidden)

        let mine = status("11", by: me, filtered: [filter("a", .hide)])
        #expect(!home.verdict(for: status("21", filtered: [filter("a", .hide)], reblog: mine), now: now).isHidden)
    }

    /// 自分の投稿は折りたたまずに、一致したフィルターの名前を扱いによらず返す。場所と期限では、ほかの投稿と同じく絞る。
    @Test func reportsFiltersMatchedByOwnStatuses() {
        let filters = [
            filter("a", .hide), filter("b", .warn), filter("c", .blur),
            filter("d", .hide, context: [.public]), filter("e", .hide, expiresAt: now.addingTimeInterval(-1)),
        ]
        let verdict = home.verdict(for: status("10", by: me, filtered: filters), now: now)
        #expect(verdict == FilterVerdict(isHidden: false, warningTitles: [], mediaTitles: [], ownMatchTitles: ["a", "b", "c"]))
        #expect(home.verdict(for: status("11", filtered: filters), now: now).ownMatchTitles.isEmpty)
    }

    /// ブーストでは、元の投稿に付いた結果を使う。元の投稿になければ、ブーストに付いた結果を使う。
    @Test func boostUsesOriginalResultsFirst() {
        let original = status("10", filtered: [filter("a", .warn)])
        let boost = status("20", filtered: [filter("b", .hide)], reblog: original)
        #expect(home.verdict(for: boost, now: now).warningTitles == ["a"])

        let boostOnly = status("21", filtered: [filter("b", .hide)], reblog: status("11"))
        #expect(home.verdict(for: boostOnly, now: now).isHidden)
    }

    @Test func revealedWarningStaysOpenForBoostsToo() {
        var warnings = FilterWarnings(filtering: home)
        let original = status("10", filtered: [filter("a", .warn), filter("b", .blur)])
        let boost = status("20", reblog: original)
        #expect(warnings.verdict(for: boost, now: now).warningTitles == ["a"])

        warnings.reveal(boost)
        #expect(warnings.verdict(for: original, now: now) == FilterVerdict(isHidden: false, warningTitles: [], mediaTitles: ["b"], ownMatchTitles: []))
    }

    @Test func warningsWithoutFilteringShowEverything() {
        #expect(FilterWarnings().verdict(for: status("10", filtered: [filter("a", .hide)]), now: now) == .none)
    }
}

struct FilteredMediaCoverTests {
    @Test func coversFilteredMediaUntilRevealed() {
        var covers = MediaCovers()
        let target = status("10")
        #expect(covers.cover(for: target, filterTitles: ["a"]) == .filtered(["a"]))

        covers.reveal(target)
        #expect(covers.cover(for: target, filterTitles: ["a"]) == nil)

        covers.hide(target)
        #expect(covers.cover(for: target, filterTitles: ["a"]) == .filtered(["a"]))
    }
}

@MainActor
struct FilteredTimelineTests {
    private let filtering = StatusFiltering(context: .home, myAccountID: me.id)

    private func store(pages: [[Status]], now: @escaping @MainActor () -> Date = { now }) -> (TimelineStore, @Sendable () -> [TimelineQuery]) {
        let recorder = QueryRecorder(pages: pages)
        let store = TimelineStore(pageSize: 3, filtering: filtering, now: now) { query in try recorder.next(query) }
        return (store, { recorder.queries })
    }

    /// 隠した投稿は並べないが、続きを読む位置には使う。1ページの全部が隠れても、その先へ進める。
    @Test func hiddenStatusesAreNotShownButStillPage() async throws {
        let hide = [filter("x", .hide)]
        let firstPage = [status("30"), status("29", filtered: hide), status("28", filtered: hide)]
        let hiddenPage = [status("27", filtered: hide), status("26", filtered: hide), status("25", filtered: hide)]
        let (store, queries) = store(pages: [firstPage, hiddenPage, [status("24")]])
        let initial = try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(firstPage[0])]
            $0.hiddenStatuses = Array(firstPage[1...])
            $0.oldestLoadedID = "28"
        }
        #expect(initial?.map(\.id) == ["30"])

        // 全部隠れたページでは止まらず、並べる投稿が出るまで続けて読む。
        let hiddenBefore = store.state.hiddenStatuses
        let older = try await expectChanges(of: { store.state }, during: { try await store.loadOlder() }) {
            $0.entries.append(.status(status("24")))
            $0.hiddenStatuses = hiddenBefore + hiddenPage
            $0.oldestLoadedID = "24"
        }
        #expect(older?.map(\.id) == ["24"])
        #expect(queries().map(\.maxID) == [nil, "28", "25"])
        #expect(store.statuses.map(\.id) == ["30", "24"])
    }

    /// 編集でフィルターに一致するようになれば外し、一致しなくなれば戻す。
    @Test func editsMoveStatusesInAndOutOfTheList() async throws {
        let (store, _) = store(pages: [[status("30"), status("29")]])
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(status("30")), .status(status("29"))]
            $0.oldestLoadedID = "29"
        }

        let hidden = status("29", filtered: [filter("x", .hide)])
        let hiding = try await expectChanges(of: { store.state }, during: { store.receive(.statusUpdate(hidden)) }) {
            $0.entries = [.status(status("30"))]
            $0.hiddenStatuses = [hidden]
        }
        #expect(hiding == .entriesChanged)
        #expect(store.statuses.map(\.id) == ["30"])

        let showing = try await expectChanges(of: { store.state }, during: { store.receive(.statusUpdate(status("29"))) }) {
            $0.entries = [.status(status("30")), .status(status("29"))]
            $0.hiddenStatuses = []
        }
        #expect(showing == .entriesChanged)
        #expect(store.statuses.map(\.id) == ["30", "29"])
    }

    /// ストリーミングで届いた隠す投稿は挿入しても並べず、加わった投稿にも数えない。同じ投稿がもう一度届いても溜めない。
    @Test func hiddenArrivalsAreNotInserted() async throws {
        let (store, _) = store(pages: [[status("30")]])
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(status("30"))]
            $0.oldestLoadedID = "30"
        }

        let hidden = status("31", filtered: [filter("x", .hide)])
        try await expectChanges(of: { store.state }, during: { store.receive(.update(hidden)) }) {
            $0.pending = [hidden]
        }
        let flushed = try await expectChanges(of: { store.state }, during: { store.flushPending() }) {
            $0.pending = []
            $0.hiddenStatuses = [hidden]
        }
        #expect(flushed.isEmpty)
        #expect(store.statuses.map(\.id) == ["30"])

        let again = try await expectChanges(of: { store.state }, during: { store.receive(.update(hidden)) }) { _ in }
        #expect(again == .none)
    }

    /// 隠していた投稿は、フィルターの期限が切れたら、次に新着を挿入したときにタイムラインに戻る。
    @Test func hiddenStatusReturnsOnInsertionAfterFilterExpires() async throws {
        let clock = FakeClock(now: now)
        let expiresAt = now.addingTimeInterval(60)
        let expiring = status("29", filtered: [filter("x", .hide, expiresAt: expiresAt)])
        let (store, _) = store(pages: [[status("30"), expiring]], now: { clock.now })
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(status("30"))]
            $0.hiddenStatuses = [expiring]
            $0.oldestLoadedID = "29"
        }
        #expect(store.statuses.map(\.id) == ["30"])

        clock.now = expiresAt.addingTimeInterval(1)
        try await expectChanges(of: { store.state }, during: { store.receive(.update(status("31"))) }) {
            $0.pending = [status("31")]
        }
        try await expectChanges(of: { store.state }, during: { store.flushPending() }) {
            $0.pending = []
            $0.hiddenStatuses = []
            $0.entries = [.status(status("31")), .status(status("30")), .status(expiring)]
        }

        #expect(store.statuses.map(\.id) == ["31", "30", "29"])
    }

    /// 最新のページが全部隠れるとタイムラインに行がなく、続きを読むきっかけがない。並べる投稿が出るまで古いページを続けて読む。
    @Test func initialPageOfOnlyHiddenStatusesReadsOn() async throws {
        let hide = [filter("x", .hide)]
        let firstPage = [status("30", filtered: hide), status("29", filtered: hide), status("28", filtered: hide)]
        let (store, queries) = store(pages: [firstPage, [status("27", filtered: hide), status("26")]])
        let initial = try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(status("26"))]
            $0.hiddenStatuses = firstPage + [status("27", filtered: hide)]
            $0.oldestLoadedID = "26"
        }
        #expect(initial?.map(\.id) == ["26"])
        #expect(queries().map(\.maxID) == [nil, "28"])
    }

    /// 古いページが全部隠れても、タイムラインの末尾が伸びるまで続けて読む。終わりに着いたらそこで止める。
    @Test func olderPageOfOnlyHiddenStatusesReadsOn() async throws {
        let hide = [filter("x", .hide)]
        let hiddenPage = [status("29", filtered: hide), status("28", filtered: hide), status("27", filtered: hide)]
        let (store, queries) = store(pages: [
            [status("30")],
            hiddenPage,
            [status("26", filtered: hide)],
            [],
        ])
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(status("30"))]
            $0.oldestLoadedID = "30"
        }
        let older = try await expectChanges(of: { store.state }, during: { try await store.loadOlder() }) {
            $0.hiddenStatuses = hiddenPage + [status("26", filtered: hide)]
            $0.oldestLoadedID = "26"
            $0.reachedEnd = true
        }
        #expect(older?.isEmpty == true)
        #expect(queries().map(\.maxID) == [nil, "30", "27", "26"])
    }

    /// サーバーはブーストにも元の投稿にも結果を付ける。元の投稿が編集でフィルターに一致しなくなれば、ブーストもタイムラインに戻す。
    @Test func editedOriginalUnhidesItsBoost() async throws {
        let hide = [filter("x", .hide)]
        let boost = status("20", filtered: hide, reblog: status("10", filtered: hide))
        let (store, _) = store(pages: [[boost], []])
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.hiddenStatuses = [boost]
            $0.oldestLoadedID = "20"
            // 並べる投稿がないので続けて古い方を読み、空のページで終わりに着く。
            $0.reachedEnd = true
        }
        #expect(store.statuses.isEmpty)

        let result = try await expectChanges(of: { store.state }, during: { store.receive(.statusUpdate(status("10"))) }) {
            $0.hiddenStatuses = []
            // サーバーが結果を付け直した投稿なので、ブーストの結果も元の投稿の空の結果にそろう。
            $0.entries = [.status(status("20", reblog: status("10")))]
        }
        #expect(result == .entriesChanged)
        #expect(store.statuses.map(\.id) == ["20"])
    }

    /// ストリーミングのブーストでは、結果がブーストの外側にだけ付くことがある。お気に入りなどの部分的な更新では、その結果を消さない。
    @Test func partialUpdateKeepsResultsOnlyOnBoost() async throws {
        let warn = [filter("x", .warn)]
        let (store, _) = store(pages: [[status("20", filtered: warn, reblog: status("10"))]])
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(status("20", filtered: warn, reblog: status("10")))]
            $0.oldestLoadedID = "20"
        }

        func favourite(_ original: Status) -> Status {
            Status(id: original.id, createdAt: original.createdAt, account: original.account, content: "<p>お気に入りした</p>", spoilerText: "", url: nil, favourited: true)
        }
        try await expectChanges(of: { store.state }, during: { store.updateStatus("10", favourite) }) {
            $0.entries = [.status(status("20", filtered: warn, reblog: favourite(status("10"))))]
        }
        let boost = try #require(store.statuses.first)
        #expect(filtering.verdict(for: boost, now: now).warningTitles == ["x"])
    }

    /// 1ページ目が全部隠れて、続きの読み込みに失敗したら、空に戻して失敗を返す。読み込み直すときに、最初の読み込みからやり直せるようにする。
    @Test func failedReadPastHiddenInitialPageLeavesStoreEmpty() async throws {
        let hide = [filter("x", .hide)]
        let recorder = QueryRecorder(results: [
            .success(TimelinePage(statuses: [status("30", filtered: hide)], isRegenerating: false)),
            .failure(Failure()),
        ])
        let store = TimelineStore(pageSize: 3, filtering: filtering) { query in try recorder.next(query) }
        try await expectChanges(of: { store.state }, during: {
            await #expect(throws: Failure.self) { try await store.loadInitial() }
        }) { _ in }
        #expect(store.isEmpty)
    }

    /// 読めなかった投稿が、読めたら隠す投稿だったときは、読めなかった行を消したことを知らせる。
    @Test func unreadableRowReplacedByHiddenStatusIsReported() async throws {
        let unreadable = UnreadableItem(id: "29", url: nil)
        let recorder = QueryRecorder(timelinePages: [
            TimelinePage(statuses: [status("30")], unreadable: [unreadable], isRegenerating: false),
        ])
        let store = TimelineStore(pageSize: 3, filtering: filtering) { query in try recorder.next(query) }
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.unreadableItems = [unreadable]
            $0.entries = [.status(status("30")), .unreadable(unreadable)]
            $0.oldestLoadedID = "29"
        }

        let hidden = status("29", filtered: [filter("x", .hide)])
        let result = try await expectChanges(of: { store.state }, during: { store.receive(.statusUpdate(hidden)) }) {
            $0.unreadableItems = []
            $0.entries = [.status(status("30"))]
            $0.hiddenStatuses = [hidden]
        }
        #expect(result == .entriesChanged)
    }

    /// 削除された投稿は、隠していても忘れる。あとで同じIDの投稿が届いても戻さない。
    /// 続きを古い方へ読む位置は、その投稿のIDのまま残す。上げると、その間を読み直すうえ、タイムラインが空になったときに末尾の位置を失うため。
    @Test func deletingHiddenStatusForgetsIt() async throws {
        let hidden = status("29", filtered: [filter("x", .hide)])
        let (store, queries) = store(pages: [[status("30"), hidden], [status("29")]])
        try await expectChanges(of: { store.state }, during: { try await store.loadInitial() }) {
            $0.entries = [.status(status("30"))]
            $0.hiddenStatuses = [hidden]
            $0.oldestLoadedID = "29"
        }

        let removed = try await expectChanges(of: { store.state }, during: { store.removeStatus("29") }) {
            $0.deletedIDs = ["29"]
            $0.hiddenStatuses = []
        }
        // 隠していた投稿なので、並びは変わらない。
        #expect(!removed)
        try await expectChanges(of: { store.state }, during: { try await store.loadOlder() }) { _ in }
        #expect(queries().last?.maxID == "29")
    }
}

@MainActor
struct FilteredNotificationTests {
    private func mention(_ id: String, _ status: Status) -> MastodonNotification {
        MastodonNotification(id: id, type: .mention, createdAt: now, account: status.account, status: status)
    }

    /// 隠す投稿についての通知は並べず、未読にも数えないが、続きを読む位置には使う。
    @Test func hidesNotificationsAboutHiddenStatuses() async throws {
        let hide = [filter("x", .hide)]
        let recorder = NotificationRecorder(pages: [
            [mention("103", status("13")), mention("102", status("12", filtered: hide)), mention("101", status("11", filtered: hide))],
            [],
        ])
        let store = NotificationStore(pageSize: 3, filtering: StatusFiltering(context: .notifications, myAccountID: me.id)) { query in
            recorder.next(query)
        }
        _ = try await store.loadInitial(markerID: "100")

        #expect(store.entries.map(\.id) == [.notification("103")])
        #expect(store.unreadCount == 1)

        _ = try await store.loadOlder()
        #expect(recorder.queries.last?.maxID == "101")

        #expect(!store.receive(mention("104", status("14", filtered: hide))))
        #expect(store.pending.isEmpty)
    }

    /// 1ページの通知が全部隠れると通知のタイムラインに行がなく、続きを読むきっかけがない。並べる通知が出るまで古いページを続けて読む。
    @Test func readsPastPagesOfOnlyHiddenNotifications() async throws {
        let hide = [filter("x", .hide)]
        let recorder = NotificationRecorder(pages: [
            [mention("103", status("13", filtered: hide)), mention("102", status("12", filtered: hide))],
            [mention("101", status("11"))],
            [mention("100", status("10", filtered: hide))],
            [],
        ])
        let store = NotificationStore(pageSize: 2, filtering: StatusFiltering(context: .notifications, myAccountID: me.id)) { query in
            recorder.next(query)
        }
        _ = try await store.loadInitial()
        #expect(store.entries.map(\.id) == [.notification("101")])

        let older = try await store.loadOlder()
        #expect(older?.isEmpty == true)
        #expect(store.reachedEnd)
        #expect(recorder.queries.map(\.maxID) == [nil, "102", "101", "100"])
    }

    /// 通知の場所を含まないフィルターは、通知には当てない。
    @Test func ignoresFiltersForHomeOnly() async throws {
        let recorder = NotificationRecorder(pages: [[mention("101", status("11", filtered: [filter("x", .hide, context: [.home])]))]])
        let store = NotificationStore(pageSize: 3, filtering: StatusFiltering(context: .notifications, myAccountID: me.id)) { query in
            recorder.next(query)
        }
        _ = try await store.loadInitial()
        #expect(store.entries.count == 1)
    }
}

private struct Failure: Error {}

private final class QueryRecorder: Sendable {
    private let state: Mutex<(results: [Result<TimelinePage, Failure>], queries: [TimelineQuery])>

    convenience init(pages: [[Status]]) {
        self.init(timelinePages: pages.map { TimelinePage(statuses: $0, isRegenerating: false) })
    }

    convenience init(timelinePages: [TimelinePage]) {
        self.init(results: timelinePages.map { .success($0) })
    }

    init(results: [Result<TimelinePage, Failure>]) {
        state = Mutex((results, []))
    }

    func next(_ query: TimelineQuery) throws(Failure) -> TimelinePage {
        try state.withLock { state throws(Failure) in
            state.queries.append(query)
            guard !state.results.isEmpty else {
                Issue.record("想定より多く読み込まれました")
                return TimelinePage(statuses: [], isRegenerating: false)
            }
            return try state.results.removeFirst().get()
        }
    }

    var queries: [TimelineQuery] { state.withLock { $0.queries } }
}

private final class NotificationRecorder: Sendable {
    private let state: Mutex<(pages: [[MastodonNotification]], queries: [TimelineQuery])>

    init(pages: [[MastodonNotification]]) {
        state = Mutex((pages, []))
    }

    func next(_ query: TimelineQuery) -> NotificationPage {
        state.withLock { state in
            state.queries.append(query)
            guard !state.pages.isEmpty else {
                Issue.record("想定より多く読み込まれました")
                return NotificationPage(notifications: [])
            }
            return NotificationPage(notifications: state.pages.removeFirst())
        }
    }

    var queries: [TimelineQuery] { state.withLock { $0.queries } }
}

/// 実際の時刻の代わりに、テストで進める時計。
@MainActor
private final class FakeClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
