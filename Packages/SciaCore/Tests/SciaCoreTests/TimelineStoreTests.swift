import Foundation
import Synchronization
import Testing
@testable import SciaCore

@MainActor
struct TimelineStoreTests {
    /// 呼ばれたmax_idを記録し、登録した順にページを返す。
    private final class PageQueue: Sendable {
        private let state: Mutex<(pages: [Result<TimelinePage, any Error>], maxIDs: [String?])>

        init(_ pages: [Result<TimelinePage, any Error>]) {
            state = Mutex((pages, []))
        }

        func next(maxID: String?) throws -> TimelinePage {
            try state.withLock { state in
                state.maxIDs.append(maxID)
                guard !state.pages.isEmpty else {
                    Issue.record("想定より多く読み込まれました")
                    return TimelinePage(statuses: [], isRegenerating: false)
                }
                return try state.pages.removeFirst().get()
            }
        }

        var maxIDs: [String?] { state.withLock { $0.maxIDs } }
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

    private func makeStore(_ queue: PageQueue) -> TimelineStore {
        TimelineStore { maxID in try queue.next(maxID: maxID) }
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
        let store = TimelineStore { _ in
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

        #expect(store.receive(.delete(statusID: "10")) == .statusesChanged)
        #expect(store.statuses.map(\.id) == ["29"])
        #expect(store.pending.isEmpty)
        #expect(store.receive(.delete(statusID: "999")) == .none)
    }

    @Test func statusUpdateReplacesStatusAndBoostedOriginal() async throws {
        let original = try status(10)
        let store = makeStore(PageQueue([.success(TimelinePage(
            statuses: [try status(30, reblog: original), try status(10)],
            isRegenerating: false
        ))]))
        _ = try await store.loadInitial()

        #expect(store.receive(.statusUpdate(try status(10, content: "編集後"))) == .statusesChanged)

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
