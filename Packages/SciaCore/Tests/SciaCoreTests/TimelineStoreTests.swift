import Foundation
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

    private func makeStore(_ queue: PageQueue) -> TimelineStore {
        TimelineStore(pageSize: Self.pageSize) { query in try queue.next(query) }
    }

    @Test func loadsInitialThenOlderPagesUsingOldestID() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([27, 26])])
        let store = makeStore(queue)

        #expect(try await store.loadInitial()?.map(\.id) == ["30", "29", "28"])
        #expect(try await store.loadOlder()?.map(\.id) == ["27", "26"])

        #expect(store.statuses.map(\.id) == ["30", "29", "28", "27", "26"])
        #expect(queue.maxIDs == [nil, "28"])
    }

    @Test func dropsDuplicatesFromOlderPage() async throws {
        let queue = PageQueue([try page([30, 29]), try page([29, 28])])
        let store = makeStore(queue)

        _ = try await store.loadInitial()
        #expect(try await store.loadOlder()?.map(\.id) == ["28"])
        #expect(store.statuses.map(\.id) == ["30", "29", "28"])
    }

    @Test func emptyOlderPageReachesEndAndStopsLoading() async throws {
        let queue = PageQueue([try page([30]), try page([])])
        let store = makeStore(queue)

        _ = try await store.loadInitial()
        #expect(try await store.loadOlder() == [])
        #expect(store.reachedEnd)
        #expect(try await store.loadOlder() == nil)
        #expect(queue.maxIDs == [nil, "30"])
    }

    @Test func regeneratingEmptyPageIsNotEnd() async throws {
        let queue = PageQueue([try page([], regenerating: true)])
        let store = makeStore(queue)

        #expect(try await store.loadInitial() == [])
        #expect(!store.reachedEnd)
        #expect(store.isRegenerating)
    }

    @Test func loadOlderBeforeInitialDoesNothing() async throws {
        let queue = PageQueue([])
        let store = makeStore(queue)

        #expect(try await store.loadOlder() == nil)
        #expect(queue.maxIDs.isEmpty)
    }

    @Test func failureKeepsStatusesAndAllowsRetry() async throws {
        let queue = PageQueue([try page([30]), .failure(Failure()), try page([29])])
        let store = makeStore(queue)

        _ = try await store.loadInitial()
        await #expect(throws: Failure.self) { _ = try await store.loadOlder() }
        #expect(!store.isLoading)
        #expect(store.statuses.map(\.id) == ["30"])

        #expect(try await store.loadOlder()?.map(\.id) == ["29"])
        #expect(queue.maxIDs == [nil, "30", "30"])
    }

    @Test func concurrentLoadIsSkipped() async throws {
        let gate = AsyncGate()
        let store = TimelineStore(pageSize: Self.pageSize) { _ in
            await gate.wait()
            return TimelinePage(statuses: [], isRegenerating: false)
        }

        let first = Task { try await store.loadInitial() }
        await gate.waitUntilWaiting()
        #expect(store.isLoading)
        #expect(try await store.loadInitial() == nil)

        await gate.open()
        #expect(try await first.value == [])
    }

    // MARK: - ストリーミング

    private func loadedStore(_ ids: [Int], reachedEnd: Bool = false) async throws -> TimelineStore {
        let pages = reachedEnd ? [try page(ids), try page([])] : [try page(ids)]
        let store = makeStore(PageQueue(pages))
        _ = try await store.loadInitial()
        if reachedEnd {
            _ = try await store.loadOlder()
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

        #expect(store.receive(.update(try status(31))) == .pendingStarted)
        #expect(store.receive(.update(try status(32))) == .none)
        #expect(store.statuses.map(\.id) == ["30", "29"])

        #expect(store.flushPending().map(\.id) == ["32", "31"])
        #expect(store.statuses.map(\.id) == ["32", "31", "30", "29"])
        #expect(store.pending.isEmpty)
        #expect(store.receive(.update(try status(33))) == .pendingStarted)
    }

    @Test func flushMergesByIDOrderAndDropsDuplicates() async throws {
        let store = try await loadedStore([30, 28])

        _ = store.receive(.update(try status(31)))
        _ = store.receive(.update(try status(29)))
        _ = store.receive(.update(try status(31)))
        _ = store.receive(.update(try status(30)))

        #expect(store.flushPending().map(\.id) == ["31", "29"])
        #expect(store.statuses.map(\.id) == ["31", "30", "29", "28"])
    }

    @Test func comparesIDsByLengthBeforeText() async throws {
        let store = try await loadedStore([99])

        _ = store.receive(.update(try status(100)))

        #expect(store.flushPending().map(\.id) == ["100"])
        #expect(store.statuses.map(\.id) == ["100", "99"])
    }

    @Test func dropsPendingOlderThanLoadedTailUnlessEndReached() async throws {
        let store = try await loadedStore([30, 29])
        _ = store.receive(.update(try status(10)))
        #expect(store.flushPending().isEmpty)
        #expect(store.statuses.map(\.id) == ["30", "29"])

        let ended = try await loadedStore([30, 29], reachedEnd: true)
        _ = ended.receive(.update(try status(10)))
        #expect(ended.flushPending().map(\.id) == ["10"])
    }

    @Test func deleteRemovesStatusAndBoostsOfIt() async throws {
        let original = try status(10)
        let store = makeStore(PageQueue([.success(TimelinePage(
            statuses: [try status(30, reblog: original), try status(29)],
            isRegenerating: false
        ))]))
        _ = try await store.loadInitial()
        _ = store.receive(.update(try status(31, reblog: original)))

        #expect(store.receive(.delete(statusID: "10")) == .entriesChanged)
        #expect(store.statuses.map(\.id) == ["29"])
        #expect(store.pending.isEmpty)
        #expect(store.receive(.delete(statusID: "999")) == .none)
    }

    /// ミュートかブロックした相手の投稿、その人のブースト、その人の投稿のブーストを除き、ほかの投稿は残す。
    /// 除いたあとに届いた投稿も足さず、解除したら、また足す。
    @Test func excludeAccountRemovesItsStatusesAndBoostsUntilIncluded() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/bob.png"))
        let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: avatar)
        func bobs(_ id: Int, reblog: Status? = nil) throws -> Status {
            Status(id: String(id), createdAt: Date(timeIntervalSince1970: TimeInterval(id)), account: bob, content: "", spoilerText: "", url: nil, reblog: reblog)
        }
        let store = makeStore(PageQueue([.success(TimelinePage(
            statuses: [try bobs(30), try status(29, reblog: try bobs(5)), try bobs(28, reblog: try status(6)), try status(27)],
            isRegenerating: false
        ))]))
        _ = try await store.loadInitial()
        _ = store.receive(.update(try bobs(31)))

        #expect(store.excludeAccount("2"))
        #expect(store.statuses.map(\.id) == ["27"])
        #expect(store.pending.isEmpty)
        #expect(!store.excludeAccount("2"))

        _ = store.receive(.update(try bobs(32)))
        #expect(store.flushPending().isEmpty)

        store.includeAccount("2")
        _ = store.receive(.update(try bobs(33)))
        #expect(store.flushPending().map(\.id) == ["33"])
    }

    /// 除いている間に届いた投稿は、届いた時点で捨てる。保留したまま解除すると、隠したはずの投稿が出てしまうため。
    @Test func includeAccountDoesNotRestoreStatusesReceivedWhileExcluded() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/bob.png"))
        let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: avatar)
        let store = try await loadedStore([30])
        store.excludeAccount("2")

        _ = store.receive(.update(Status(id: "31", createdAt: .now, account: bob, content: "", spoilerText: "", url: nil)))
        #expect(store.pending.isEmpty)
        store.includeAccount("2")

        #expect(store.flushPending().isEmpty)
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
        let store = TimelineStore(pageSize: Self.pageSize) { query in
            queries.withLock { $0.append(query.maxID) }
            switch query.maxID {
            case nil: return TimelinePage(statuses: initial, isRegenerating: false)
            case "30": return await gate.fetch()
            case "27": return TimelinePage(statuses: older, isRegenerating: false)
            default: return TimelinePage(statuses: [], isRegenerating: false)
            }
        }
        _ = try await store.loadInitial()
        await gate.hold()
        let read = Task { try await store.loadOlder() }
        await gate.waitForRequest()

        store.excludeAccount("2")
        await gate.release()
        _ = try await read.value

        #expect(store.statuses.map(\.id) == ["30", "26"])
        #expect(queries.withLock { $0 } == [nil, "30", "27"])
    }

    @Test func statusUpdateReplacesStatusAndBoostedOriginal() async throws {
        let original = try status(10)
        let store = makeStore(PageQueue([.success(TimelinePage(
            statuses: [try status(30, reblog: original), try status(10)],
            isRegenerating: false
        ))]))
        _ = try await store.loadInitial()

        #expect(store.receive(.statusUpdate(try status(10, content: "編集後"))) == .entriesChanged)

        #expect(store.statuses.map(\.displayed.content) == ["編集後", "編集後"])
        #expect(store.statuses.first?.id == "30")
        #expect(store.receive(.statusUpdate(try status(999))) == .none)
    }

    @Test func unreadCountsStatusesNewerThanLastRead() async throws {
        let store = try await loadedStore([30, 29, 28])
        #expect(store.unreadCount == 0)

        store.markRead(["29", "28"])
        #expect(store.lastReadID == "29")
        #expect(store.unreadCount == 1)

        _ = store.receive(.update(try status(31)))
        _ = store.flushPending()
        #expect(store.unreadCount == 2)

        store.markRead(["28"])
        #expect(store.lastReadID == "29")

        store.markRead(["31"])
        #expect(store.unreadCount == 0)
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
