import Foundation
import Synchronization
import Testing
@testable import SciaCore

@MainActor
struct TimelinePagerTests {
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

    private func makePager(_ queue: PageQueue) -> TimelinePager {
        TimelinePager { maxID in try queue.next(maxID: maxID) }
    }

    @Test func loadsInitialThenOlderPagesUsingOldestID() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([27, 26])])
        let pager = makePager(queue)

        #expect(try await pager.loadInitial()?.map(\.id) == ["30", "29", "28"])
        #expect(try await pager.loadOlder()?.map(\.id) == ["27", "26"])

        #expect(pager.statuses.map(\.id) == ["30", "29", "28", "27", "26"])
        #expect(queue.maxIDs == [nil, "28"])
    }

    @Test func dropsDuplicatesFromOlderPage() async throws {
        let queue = PageQueue([try page([30, 29]), try page([29, 28])])
        let pager = makePager(queue)

        _ = try await pager.loadInitial()
        #expect(try await pager.loadOlder()?.map(\.id) == ["28"])
        #expect(pager.statuses.map(\.id) == ["30", "29", "28"])
    }

    @Test func emptyOlderPageReachesEndAndStopsLoading() async throws {
        let queue = PageQueue([try page([30]), try page([])])
        let pager = makePager(queue)

        _ = try await pager.loadInitial()
        #expect(try await pager.loadOlder() == [])
        #expect(pager.reachedEnd)
        #expect(try await pager.loadOlder() == nil)
        #expect(queue.maxIDs == [nil, "30"])
    }

    @Test func regeneratingEmptyPageIsNotEnd() async throws {
        let queue = PageQueue([try page([], regenerating: true)])
        let pager = makePager(queue)

        #expect(try await pager.loadInitial() == [])
        #expect(!pager.reachedEnd)
    }

    @Test func loadOlderBeforeInitialDoesNothing() async throws {
        let queue = PageQueue([])
        let pager = makePager(queue)

        #expect(try await pager.loadOlder() == nil)
        #expect(queue.maxIDs.isEmpty)
    }

    @Test func failureKeepsStatusesAndAllowsRetry() async throws {
        let queue = PageQueue([try page([30]), .failure(Failure()), try page([29])])
        let pager = makePager(queue)

        _ = try await pager.loadInitial()
        await #expect(throws: Failure.self) { _ = try await pager.loadOlder() }
        #expect(!pager.isLoading)
        #expect(pager.statuses.map(\.id) == ["30"])

        #expect(try await pager.loadOlder()?.map(\.id) == ["29"])
        #expect(queue.maxIDs == [nil, "30", "30"])
    }

    @Test func concurrentLoadIsSkipped() async throws {
        let gate = AsyncGate()
        let pager = TimelinePager { _ in
            await gate.wait()
            return TimelinePage(statuses: [], isRegenerating: false)
        }

        let first = Task { try await pager.loadInitial() }
        await gate.waitUntilWaiting()
        #expect(pager.isLoading)
        #expect(try await pager.loadInitial() == nil)

        await gate.open()
        #expect(try await first.value == [])
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
