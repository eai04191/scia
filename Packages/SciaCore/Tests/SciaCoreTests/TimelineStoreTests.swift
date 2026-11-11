import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

@MainActor
struct TimelineStoreTests {
    /// 呼ばれた範囲を記録し、登録した順にページを返す。
    private final class PageQueue: Sendable {
        private let state: Mutex<(pages: [Result<TimelinePage, any Error>], queries: [TimelineQuery])>

        init(_ pages: [Result<TimelinePage, any Error>]) {
            state = Mutex((pages, []))
        }

        func next(_ query: TimelineQuery) throws -> TimelinePage {
            try state.withLock { state in
                state.queries.append(query)
                guard !state.pages.isEmpty else {
                    Issue.record("想定より多く読み込まれました")
                    return TimelinePage(statuses: [], isRegenerating: false)
                }
                return try state.pages.removeFirst().get()
            }
        }

        var queries: [TimelineQuery] { state.withLock { $0.queries } }
        var maxIDs: [String?] { queries.map(\.maxID) }
    }

    private struct Failure: Error {}

    private func statuses(_ ids: [Int]) throws -> [Status] {
        let avatar = try #require(URL(string: "https://example.social/avatars/alice.png"))
        return ids.map { id in
            Status(
                id: String(id),
                createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
                account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: avatar),
                content: "<p>\(id)</p>",
                spoilerText: "",
                url: nil
            )
        }
    }

    private func page(_ ids: [Int], regenerating: Bool = false) throws -> Result<TimelinePage, any Error> {
        .success(TimelinePage(statuses: try statuses(ids), isRegenerating: regenerating))
    }

    /// テストで扱いやすいよう、1ページを3件にする。
    private static let pageSize = 3

    private func makeStore(_ queue: PageQueue) -> TimelineStoreTester {
        TimelineStoreTester(pageSize: Self.pageSize) { query in try queue.next(query) }
    }

    /// 並びの`entries`に入る、`statuses(_:)`の投稿。
    private func entries(_ ids: [Int]) throws -> [TimelineEntry] {
        try statuses(ids).map(TimelineEntry.status)
    }

    @Test func loadsInitialThenOlderPagesUsingOldestID() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([27, 26])])
        let store = makeStore(queue)

        let initial = try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = try entries([30, 29, 28])
            $0.oldestLoadedID = "28"
        }
        #expect(initial?.map(\.id) == ["30", "29", "28"])
        let older = try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.entries += try entries([27, 26])
            $0.oldestLoadedID = "26"
        }
        #expect(older?.map(\.id) == ["27", "26"])

        #expect(store.statuses.map(\.id) == ["30", "29", "28", "27", "26"])
        #expect(queue.maxIDs == [nil, "28"])
    }

    @Test func dropsDuplicatesFromOlderPage() async throws {
        let queue = PageQueue([try page([30, 29]), try page([29, 28])])
        let store = makeStore(queue)

        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = try entries([30, 29])
            $0.oldestLoadedID = "29"
        }
        let older = try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.entries += try entries([28])
            $0.oldestLoadedID = "28"
        }
        #expect(older?.map(\.id) == ["28"])
        #expect(store.statuses.map(\.id) == ["30", "29", "28"])
    }

    @Test func emptyOlderPageReachesEndAndStopsLoading() async throws {
        let queue = PageQueue([try page([30]), try page([])])
        let store = makeStore(queue)

        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = try entries([30])
            $0.oldestLoadedID = "30"
        }
        let older = try await store.expectChanges(during: { store in try await store.loadOlder() }) {
            $0.reachedEnd = true
        }
        #expect(older == [])
        let again = try await store.expectChanges(during: { store in try await store.loadOlder() }) { _ in }
        #expect(again == nil)
        #expect(queue.maxIDs == [nil, "30"])
    }

    @Test func regeneratingEmptyPageIsNotEnd() async throws {
        let queue = PageQueue([try page([], regenerating: true)])
        let store = makeStore(queue)

        let loaded = try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.isRegenerating = true
            // 空のまま再生成中なので、次の補完も最新のページから読む。
            $0.fillsFromLatestPage = true
        }
        #expect(loaded == [])
    }

    @Test func loadOlderBeforeInitialDoesNothing() async throws {
        let queue = PageQueue([])
        let store = makeStore(queue)

        let older = try await store.expectChanges(during: { store in try await store.loadOlder() }) { _ in }
        #expect(older == nil)
        #expect(queue.maxIDs.isEmpty)
    }

    @Test func failureKeepsStatusesAndAllowsRetry() async throws {
        let queue = PageQueue([try page([30]), .failure(Failure()), try page([29])])
        let store = makeStore(queue)

        let older = try status(29)

        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = try entries([30])
            $0.oldestLoadedID = "30"
        }
        try await store.expectChanges(during: { store in
            await #expect(throws: Failure.self) { _ = try await store.loadOlder() }
        }) { _ in }

        let retried = try await store.expectChanges(during: { store in try await store.loadOlder()?.map(\.id) }) {
            $0.entries.append(.status(older))
            $0.oldestLoadedID = "29"
        }
        #expect(retried == ["29"])
        #expect(queue.maxIDs == [nil, "30", "30"])
    }

    @Test func concurrentLoadIsSkipped() async throws {
        let gate = AsyncGate()
        let store = TimelineStoreTester(pageSize: Self.pageSize) { _ in
            await gate.wait()
            return TimelinePage(statuses: [], isRegenerating: false)
        }

        let first = try await store.expectChanges(during: { store -> Task<[Status]?, any Error> in
            let first = Task { try await store.loadInitial() }
            await gate.waitUntilWaiting()
            return first
        }) {
            $0.isLoading = true
        }
        let second = try await store.expectChanges(during: { store in try await store.loadInitial() }) { _ in }
        #expect(second == nil)

        let loaded = try await store.expectChanges(during: { store in
            await gate.open()
            return try await first.value
        }) {
            $0.isLoading = false
            // 再生成中でない空のページなので、これより古い投稿はない。
            $0.reachedEnd = true
        }
        #expect(loaded == [])
    }

    // MARK: - ストリーミング

    /// `ids`を読み込んだストア。`ids`は1件以上で、新しい順に渡す。
    private func loadedStore(_ ids: [Int], reachedEnd: Bool = false) async throws -> TimelineStoreTester {
        let pages = reachedEnd ? [try page(ids), try page([])] : [try page(ids)]
        let store = makeStore(PageQueue(pages))
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = try entries(ids)
            $0.oldestLoadedID = ids.last.map(String.init)
        }
        if reachedEnd {
            try await store.expectChanges(during: { store in try await store.loadOlder() }) {
                $0.reachedEnd = true
            }
        }
        return store
    }

    private func status(_ id: Int, content: String? = nil, reblog: Status? = nil) throws -> Status {
        let base = try #require(try statuses([id]).first)
        return Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: content ?? base.content,
            spoilerText: "",
            url: nil,
            reblog: reblog
        )
    }

    @Test func updatesArePendingUntilFlushed() async throws {
        let store = try await loadedStore([30, 29])
        let first = try status(31)
        let second = try status(32)

        let firstResult = try await store.expectChanges(during: { store in store.receive(.update(first)) }) {
            $0.pending = [first]
        }
        #expect(firstResult == .pendingStarted)
        let secondResult = try await store.expectChanges(during: { store in store.receive(.update(second)) }) {
            $0.pending.append(second)
        }
        #expect(secondResult == .none)
        let flushed = try await store.expectChanges(during: { store in store.flushPending().map(\.id) }) {
            $0.pending = []
            $0.entries.insert(contentsOf: [.status(second), .status(first)], at: 0)
        }
        #expect(flushed == ["32", "31"])
        let third = try status(33)
        let thirdResult = try await store.expectChanges(during: { store in store.receive(.update(third)) }) {
            $0.pending = [third]
        }
        #expect(thirdResult == .pendingStarted)
    }

    /// 一番上の投稿より古いIDの投稿が遅れて届いても、読み終えた行の間に入れず、届いた順に一番上へ積む。
    @Test func flushStacksArrivalsInArrivalOrderAndDropsDuplicates() async throws {
        let store = try await loadedStore([30, 28])

        try await store.expectChanges(during: { store in
            _ = store.receive(.update(try status(31)))
            _ = store.receive(.update(try status(29)))
        }) {
            $0.pending = [try status(31), try status(29)]
        }
        // 保留中の投稿と、並べてある投稿は溜めない。
        try await store.expectChanges(during: { store in
            _ = store.receive(.update(try status(31)))
            _ = store.receive(.update(try status(30)))
        }) { _ in }

        let flushed = try await store.expectChanges(during: { store in store.flushPending().map(\.id) }) {
            $0.pending = []
            $0.entries.insert(contentsOf: [.status(try status(29)), .status(try status(31))], at: 0)
            // 29は、そのとき一番上だった31の上に積む。
            $0.lateArrivalSequence = 1
            $0.lateArrivalPositions["29"] = TimelineStore.DisplayPosition(anchorID: "31", sequence: 1)
        }
        #expect(flushed == ["29", "31"])

        try await store.expectChanges(during: { store in
            _ = store.receive(.update(try status(32)))
            _ = store.flushPending()
        }) {
            // 32は一番上の31より新しいので、積まずにIDの位置に入り、一番上になる。
            $0.entries.insert(.status(try status(32)), at: 0)
        }
        #expect(store.statuses.map(\.id) == ["32", "29", "31", "30", "28"])
    }

    @Test func comparesIDsByLengthBeforeText() async throws {
        let store = try await loadedStore([99])

        let new = try status(100)
        try await store.expectChanges(during: { store in store.receive(.update(new)) }) {
            $0.pending = [new]
        }

        let flushed = try await store.expectChanges(during: { store in store.flushPending().map(\.id) }) {
            $0.pending = []
            $0.entries.insert(.status(new), at: 0)
        }
        #expect(flushed == ["100"])
        #expect(store.statuses.map(\.id) == ["100", "99"])
    }

    @Test func dropsPendingOlderThanLoadedTailUnlessEndReached() async throws {
        let store = try await loadedStore([30, 29])
        let old = try status(10)
        try await store.expectChanges(during: { store in store.receive(.update(old)) }) {
            $0.pending = [old]
        }
        let flushed = try await store.expectChanges(during: { store in store.flushPending() }) {
            $0.pending = []
            // 捨てずに取っておき、古い方を読んで末尾がそれより下がったら並べる。
            $0.olderArrivals = [old]
        }
        #expect(flushed.isEmpty)
        #expect(store.statuses.map(\.id) == ["30", "29"])

        let ended = try await loadedStore([30, 29], reachedEnd: true)
        try await ended.expectChanges(during: { ended in ended.receive(.update(old)) }) {
            $0.pending = [old]
        }
        let endedFlushed = try await ended.expectChanges(during: { ended in ended.flushPending().map(\.id) }) {
            $0.pending = []
            // 一番上の30より古いので、遅れて届いた投稿として一番上に積む。末尾には足さない。
            $0.entries.insert(.status(old), at: 0)
            $0.lateArrivalSequence = 1
            $0.lateArrivalPositions["10"] = TimelineStore.DisplayPosition(anchorID: "30", sequence: 1)
            $0.oldestLoadedID = "10"
        }
        #expect(endedFlushed == ["10"])
    }

    @Test func deleteRemovesStatusAndBoostsOfIt() async throws {
        let original = try status(10)
        let boost = try status(30, reblog: original)
        let store = makeStore(PageQueue([.success(TimelinePage(
            statuses: [boost, try status(29)],
            isRegenerating: false
        ))]))
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = [.status(boost), .status(try status(29))]
            $0.oldestLoadedID = "29"
        }
        let pendingBoost = try status(31, reblog: original)
        try await store.expectChanges(during: { store in store.receive(.update(pendingBoost)) }) {
            $0.pending = [pendingBoost]
        }

        let deleted = try await store.expectChanges(during: { store in store.receive(.delete(statusID: "10")) }) {
            $0.deletedIDs.insert("10")
            $0.pending = []
            $0.entries.removeFirst()
        }
        #expect(deleted == .entriesChanged)
        let unknown = try await store.expectChanges(during: { store in store.receive(.delete(statusID: "999")) }) {
            // 表示に関わる変化はなくても、あとから届いたときに足さないよう覚える。
            $0.deletedIDs.insert("999")
        }
        #expect(unknown == .none)
    }

    /// ミュートかブロックした相手の投稿、その人のブースト、その人の投稿のブーストを除き、ほかの投稿は残す。
    /// 除いたあとに届いた投稿も足さず、解除したら、また足す。
    @Test func excludeAccountRemovesItsStatusesAndBoostsUntilIncluded() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/bob.png"))
        let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: avatar)
        func bobs(_ id: Int, reblog: Status? = nil) throws -> Status {
            Status(id: String(id), createdAt: Date(timeIntervalSince1970: TimeInterval(id)), account: bob, content: "", spoilerText: "", url: nil, reblog: reblog)
        }
        let loaded = [try bobs(30), try status(29, reblog: try bobs(5)), try bobs(28, reblog: try status(6)), try status(27)]
        let store = makeStore(PageQueue([.success(TimelinePage(statuses: loaded, isRegenerating: false))]))
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = loaded.map(TimelineEntry.status)
            $0.oldestLoadedID = "27"
        }
        try await store.expectChanges(during: { store in store.receive(.update(try bobs(31))) }) {
            $0.pending = [try bobs(31)]
        }

        let excluded = try await store.expectChanges(during: { store in store.excludeAccount("2") }) {
            $0.excludedAccountIDs = ["2"]
            $0.pending = []
            $0.entries = [.status(try status(27))]
        }
        #expect(excluded)
        #expect(store.statuses.map(\.id) == ["27"])
        let again = try await store.expectChanges(during: { store in store.excludeAccount("2") }) { _ in }
        #expect(!again)

        try await store.expectChanges(during: { store in store.receive(.update(try bobs(32))) }) { _ in }
        let flushedWhileExcluded = try await store.expectChanges(during: { store in store.flushPending() }) { _ in }
        #expect(flushedWhileExcluded.isEmpty)

        try await store.expectChanges(during: { store in store.includeAccount("2") }) {
            $0.excludedAccountIDs = []
        }
        try await store.expectChanges(during: { store in store.receive(.update(try bobs(33))) }) {
            $0.pending = [try bobs(33)]
        }
        let flushed = try await store.expectChanges(during: { store in store.flushPending().map(\.id) }) {
            $0.pending = []
            $0.entries.insert(.status(try bobs(33)), at: 0)
        }
        #expect(flushed == ["33"])
    }

    /// ミュートしたハッシュタグの付いた投稿でも、自分の投稿は除かない。サーバーのフィルターを自分の投稿に当てないのと揃える（docs/filters.md）。
    @Test func excludeTagKeepsOwnStatuses() async throws {
        let base = try status(30)
        let own = Status(id: base.id, createdAt: base.createdAt, account: base.account, content: "", spoilerText: "", url: nil, tags: [Tag(name: "cat", url: nil)])
        let store = TimelineStoreTester(pageSize: Self.pageSize, filtering: StatusFiltering(context: .home, myAccountID: base.account.id)) { _ in
            TimelinePage(statuses: [own], isRegenerating: false)
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = [.status(own)]
            $0.oldestLoadedID = "30"
        }

        let excluded = try await store.expectChanges(during: { store in store.excludeTag("cat") }) {
            $0.excludedTagKeys = ["#cat"]
        }
        #expect(!excluded)
    }

    /// ミュートしたハッシュタグの付いた投稿とそのブーストを、保留中のものも含めて出さず、あとから届いても出さない。解除したら、次に並べ直したときに戻る。
    /// 同じタグかは、サーバーのフィルターと同じく、大文字と小文字だけをそろえて見る。全角の表記は別のタグとして扱う。
    @Test func excludeTagRemovesTaggedStatusesAndBoostsUntilIncluded() async throws {
        func tagged(_ id: Int, _ name: String) throws -> Status {
            let base = try status(id)
            return Status(id: base.id, createdAt: base.createdAt, account: base.account, content: "", spoilerText: "", url: nil, tags: [Tag(name: name, url: nil)])
        }
        let cat = try tagged(30, "Cat")
        let catBoost = try status(29, reblog: try tagged(5, "cat"))
        let dog = try tagged(28, "dog")
        let plain = try status(27)
        let upperCat = try tagged(31, "CAT")
        let fullWidthCat = try tagged(32, "ｃａｔ")
        let store = makeStore(PageQueue([.success(TimelinePage(statuses: [cat, catBoost, dog, plain], isRegenerating: false))]))
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = [cat, catBoost, dog, plain].map(TimelineEntry.status)
            $0.oldestLoadedID = "27"
        }
        try await store.expectChanges(during: { store in
            _ = store.receive(.update(upperCat))
            _ = store.receive(.update(fullWidthCat))
        }) {
            $0.pending = [upperCat, fullWidthCat]
        }

        let excluded = try await store.expectChanges(during: { store in store.excludeTag("cat") }) {
            $0.excludedTagKeys = ["#cat"]
            $0.entries = [.status(dog), .status(plain)]
            // 捨てずに、続きを読む位置に数えるため別に持つ。保留中の投稿は、並べるときに分ける。
            $0.hiddenStatuses = [cat, catBoost]
        }
        #expect(excluded)
        #expect(store.statuses.map(\.id) == ["28", "27"])
        let again = try await store.expectChanges(during: { store in store.excludeTag("cat") }) { _ in }
        #expect(!again)
        // ミュートの前に始まった読み込みの結果のように、フィルターの結果の付いていない投稿があとから届いても出さない。全角の表記はサーバーも隠さない。
        let flushedWhileExcluded = try await store.expectChanges(during: { store in store.flushPending().map(\.id) }) {
            $0.pending = []
            $0.entries.insert(.status(fullWidthCat), at: 0)
            $0.hiddenStatuses.append(upperCat)
        }
        #expect(flushedWhileExcluded == ["32"])

        // 解除しただけでは並べ直さない。
        try await store.expectChanges(during: { store in store.includeTag("Cat") }) {
            $0.excludedTagKeys = []
        }
        let newCat = try tagged(33, "cat")
        try await store.expectChanges(during: { store in store.receive(.update(newCat)) }) {
            $0.pending = [newCat]
        }
        let flushed = try await store.expectChanges(during: { store in store.flushPending().map(\.id) }) {
            $0.pending = []
            $0.hiddenStatuses = []
            $0.entries = [newCat, fullWidthCat, upperCat, cat, catBoost, dog, plain].map(TimelineEntry.status)
        }
        #expect(flushed == ["33"])
        #expect(store.statuses.map(\.id) == ["33", "32", "31", "30", "29", "28", "27"])
    }

    /// 最初のページの全部がミュートしたハッシュタグの投稿でも、その先の古い投稿を読める。出さない投稿も続きを読む位置に数え、
    /// フィルターで隠れたページと同じく、最初の読み込みが続きを読むため。
    @Test func pageOfMutedTagStillReachesOlderStatuses() async throws {
        func tagged(_ id: Int) throws -> Status {
            let base = try status(id)
            return Status(id: base.id, createdAt: base.createdAt, account: base.account, content: "", spoilerText: "", url: nil, tags: [Tag(name: "cat", url: nil)])
        }
        let muted = [try tagged(32), try tagged(31)]
        let queue = PageQueue([.success(TimelinePage(statuses: muted, isRegenerating: false)), try page([30])])
        let store = makeStore(queue)
        try await store.expectChanges(during: { store in store.excludeTag("cat") }) {
            $0.excludedTagKeys = ["#cat"]
        }

        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = try entries([30])
            $0.hiddenStatuses = muted
            $0.oldestLoadedID = "30"
        }

        #expect(store.statuses.map(\.id) == ["30"])
        #expect(queue.queries.last?.maxID == "31")
    }

    /// 除いている間に届いた投稿は、届いた時点で捨てる。保留したまま解除すると、隠したはずの投稿が出てしまうため。
    @Test func includeAccountDoesNotRestoreStatusesReceivedWhileExcluded() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/bob.png"))
        let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: avatar)
        let store = try await loadedStore([30])
        try await store.expectChanges(during: { store in store.excludeAccount("2") }) {
            $0.excludedAccountIDs = ["2"]
        }

        try await store.expectChanges(during: { store in
            store.receive(.update(Status(id: "31", createdAt: Date(timeIntervalSince1970: 0), account: bob, content: "", spoilerText: "", url: nil)))
        }) { _ in }
        try await store.expectChanges(during: { store in store.includeAccount("2") }) {
            $0.excludedAccountIDs = []
        }

        let flushed = try await store.expectChanges(during: { store in store.flushPending() }) { _ in }
        #expect(flushed.isEmpty)
    }

    /// 古いページを読んでいる間にミュートかブロックをして、届いたページが全部その人の投稿でも、ページの一番古い投稿の先から続きを読む。
    @Test func olderPageOfExcludedAccountStillAdvances() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/bob.png"))
        let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: avatar)
        let bobs = [29, 28, 27].map { Status(id: String($0), createdAt: Date(timeIntervalSince1970: TimeInterval($0)), account: bob, content: "", spoilerText: "", url: nil) }
        let gate = PageGate(TimelinePage(statuses: bobs, isRegenerating: false))
        let queries = Mutex<[String?]>([])
        let initial = try statuses([30])
        let older = try statuses([26])
        let store = TimelineStoreTester(pageSize: Self.pageSize) { query in
            queries.withLock { $0.append(query.maxID) }
            switch query.maxID {
            case nil: return TimelinePage(statuses: initial, isRegenerating: false)
            case "30": return await gate.fetch()
            case "27": return TimelinePage(statuses: older, isRegenerating: false)
            default: return TimelinePage(statuses: [], isRegenerating: false)
            }
        }
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = initial.map(TimelineEntry.status)
            $0.oldestLoadedID = "30"
        }
        await gate.hold()
        let read = try await store.expectChanges(during: { store -> Task<[Status]?, any Error> in
            let read = Task { try await store.loadOlder() }
            await gate.waitForRequest()
            return read
        }) {
            $0.isLoading = true
        }

        try await store.expectChanges(during: { store in store.excludeAccount("2") }) {
            $0.excludedAccountIDs = ["2"]
        }
        let added = try await store.expectChanges(during: { store in
            await gate.release()
            return try await read.value
        }) {
            $0.isLoading = false
            $0.entries += older.map(TimelineEntry.status)
            $0.oldestLoadedID = "26"
        }
        #expect(added?.map(\.id) == ["26"])

        #expect(store.statuses.map(\.id) == ["30", "26"])
        #expect(queries.withLock { $0 } == [nil, "30", "27"])
    }

    @Test func statusUpdateReplacesStatusAndBoostedOriginal() async throws {
        let original = try status(10)
        let store = makeStore(PageQueue([.success(TimelinePage(
            statuses: [try status(30, reblog: original), original],
            isRegenerating: false
        ))]))
        try await store.expectChanges(during: { store in try await store.loadInitial() }) {
            $0.entries = [.status(try status(30, reblog: original)), .status(original)]
            $0.oldestLoadedID = "10"
        }

        let edited = try status(10, content: "編集後")
        let result = try await store.expectChanges(during: { store in store.receive(.statusUpdate(edited)) }) {
            $0.entries = [.status(try status(30, reblog: edited)), .status(edited)]
        }
        #expect(result == .entriesChanged)

        #expect(store.statuses.map(\.displayed.content) == ["編集後", "編集後"])
        #expect(store.statuses.first?.id == "30")
        let unknown = try await store.expectChanges(during: { store in store.receive(.statusUpdate(try status(999))) }) { _ in }
        #expect(unknown == .none)
    }

    @Test func unreadCountsStatusesNewerThanLastRead() async throws {
        let store = try await loadedStore([30, 29, 28])
        #expect(store.unreadCount == 0)

        try await store.expectChanges(during: { store in #expect(store.markRead(["29", "28"])) }) {
            $0.lastReadID = "29"
            #if DEBUG
            $0.lastSavableReadID = "29"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "29", sequence: 0)
        }
        #expect(store.unreadCount == 1)

        try await store.expectChanges(during: { store in
            _ = store.receive(.update(try status(31)))
            _ = store.flushPending()
        }) {
            $0.entries.insert(.status(try status(31)), at: 0)
        }
        #expect(store.unreadCount == 2)

        try await store.expectChanges(during: { store in
            #expect(!store.markRead(["28"]), "既読の位置より下の投稿を見ても、未読の数は変わりません")
        }) { _ in }

        try await store.expectChanges(during: { store in #expect(store.markRead(["31"])) }) {
            $0.lastReadID = "31"
            #if DEBUG
            $0.lastSavableReadID = "31"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "31", sequence: 0)
        }
        #expect(store.unreadCount == 0)
    }

    /// 遅れて届いて一番上に積んだ投稿は、IDが既読の位置より古くても未読に数える。サーバーに保存する既読位置は戻さない。
    @Test func lateArrivalOnTopCountsAsUnread() async throws {
        let store = try await loadedStore([30, 28])
        try await store.expectChanges(during: { store in store.markRead(["30"]) }) {
            $0.lastReadID = "30"
            #if DEBUG
            $0.lastSavableReadID = "30"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "30", sequence: 0)
        }

        try await store.expectChanges(during: { store in
            _ = store.receive(.update(try status(29)))
            _ = store.flushPending()
        }) {
            $0.entries.insert(.status(try status(29)), at: 0)
            $0.lateArrivalSequence = 1
            $0.lateArrivalPositions["29"] = TimelineStore.DisplayPosition(anchorID: "30", sequence: 1)
        }
        #expect(store.unreadCount == 1)

        try await store.expectChanges(during: { store in
            #expect(store.markRead(["29"]), "IDが既読より古くても、上に積んだ投稿を見れば既読の位置は進みます")
        }) {
            // サーバーに保存するIDは戻さず、位置だけ積んだ投稿まで進める。
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "30", sequence: 1)
        }
        #expect(store.unreadCount == 0)
    }

    /// 積んだときの一番上の投稿が消えても、次に遅れて届いた投稿は、積んである投稿よりさらに上に積む。
    @Test func lateArrivalStaysOnTopAfterAnchorIsDeleted() async throws {
        let store = try await loadedStore([30, 20])
        try await store.expectChanges(during: { store in
            _ = store.receive(.update(try status(25)))
            _ = store.flushPending()
        }) {
            $0.entries.insert(.status(try status(25)), at: 0)
            $0.lateArrivalSequence = 1
            $0.lateArrivalPositions["25"] = TimelineStore.DisplayPosition(anchorID: "30", sequence: 1)
        }
        try await store.expectChanges(during: { store in store.markRead(["25"]) }) {
            $0.lastReadID = "25"
            #if DEBUG
            $0.lastSavableReadID = "25"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "30", sequence: 1)
        }
        try await store.expectChanges(during: { store in store.receive(.delete(statusID: "30")) }) {
            $0.deletedIDs = ["30"]
            // 積んだ投稿の位置は、基準の30が消えても30のまま持つ。
            $0.entries.remove(at: 1)
        }

        try await store.expectChanges(during: { store in
            _ = store.receive(.update(try status(24)))
            _ = store.flushPending()
        }) {
            $0.entries.insert(.status(try status(24)), at: 0)
            $0.lateArrivalSequence = 2
            $0.lateArrivalPositions["24"] = TimelineStore.DisplayPosition(anchorID: "30", sequence: 2)
        }

        #expect(store.statuses.map(\.id) == ["24", "25", "20"])
        #expect(store.unreadCount == 1)
    }

    /// サーバーの既読位置はIDで取り込む。同じIDの投稿が遅れて届いて一番上に積んであっても、その下の投稿まで既読にしない。
    @Test func savedMarkerMatchingLateArrivalDoesNotReadStatusesBelowIt() async throws {
        let store = try await loadedStore([30, 20])
        try await store.expectChanges(during: { store in store.applySavedMarker("20") }) {
            $0.lastReadID = "20"
            #if DEBUG
            $0.lastSavableReadID = "20"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "20", sequence: 0)
            $0.savedReadID = "20"
        }
        try await store.expectChanges(during: { store in
            _ = store.receive(.update(try status(25)))
            _ = store.flushPending()
        }) {
            $0.entries.insert(.status(try status(25)), at: 0)
            $0.lateArrivalSequence = 1
            $0.lateArrivalPositions["25"] = TimelineStore.DisplayPosition(anchorID: "30", sequence: 1)
        }
        #expect(store.unreadCount == 2)

        try await store.expectChanges(during: { store in store.applySavedMarker("25") }) {
            $0.lastReadID = "25"
            #if DEBUG
            $0.lastSavableReadID = "25"
            #endif
            $0.lastReadPosition = TimelineStore.DisplayPosition(anchorID: "25", sequence: 0)
            $0.savedReadID = "25"
        }

        #expect(store.unreadCount == 2)
    }
}

/// 読み込みを途中で止めておくための門。
private actor AsyncGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            isWaiting = true
            arrival?.resume()
            arrival = nil
        }
    }

    func waitUntilWaiting() async {
        if isWaiting { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}
