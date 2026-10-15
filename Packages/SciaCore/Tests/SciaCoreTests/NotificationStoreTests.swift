import Foundation
import Synchronization
import Testing
@testable import SciaCore

@MainActor
struct NotificationStoreTests {
    /// 呼ばれた範囲を記録し、登録した順にページを返す。
    private final class PageQueue: Sendable {
        private let state: Mutex<(pages: [Result<[MastodonNotification], any Error>], queries: [TimelineQuery])>

        init(_ pages: [Result<[MastodonNotification], any Error>]) {
            state = Mutex((pages, []))
        }

        func next(_ query: TimelineQuery) throws -> [MastodonNotification] {
            try state.withLock { state in
                state.queries.append(query)
                guard !state.pages.isEmpty else {
                    Issue.record("想定より多く読み込まれました")
                    return []
                }
                return try state.pages.removeFirst().get()
            }
        }

        var queries: [TimelineQuery] { state.withLock { $0.queries } }
    }

    private struct Failure: Error {}

    private func notifications(_ ids: [Int]) throws -> [MastodonNotification] {
        let avatar = try #require(URL(string: "https://example.social/avatars/bob.png"))
        return ids.map { id in
            MastodonNotification(
                id: String(id),
                type: .follow,
                createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
                account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: avatar)
            )
        }
    }

    private func page(_ ids: [Int]) throws -> Result<[MastodonNotification], any Error> {
        .success(try notifications(ids))
    }

    /// テストで扱いやすいよう、1ページを3件にする。
    private static let pageSize = 3

    private func makeStore(_ queue: PageQueue) -> NotificationStore {
        NotificationStore(pageSize: Self.pageSize) { query in NotificationPage(notifications: try queue.next(query)) }
    }

    private func ids(_ store: NotificationStore) -> [String] {
        store.notifications.map(\.id)
    }

    @Test func loadsInitialThenOlderPagesUsingOldestID() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([27, 26]), try page([])])
        let store = makeStore(queue)

        #expect(try await store.loadInitial()?.map(\.id) == ["30", "29", "28"])
        #expect(try await store.loadOlder()?.map(\.id) == ["27", "26"])
        #expect(try await store.loadOlder()?.isEmpty == true)

        #expect(ids(store) == ["30", "29", "28", "27", "26"])
        #expect(store.reachedEnd)
        #expect(queue.queries.map(\.maxID) == [nil, "28", "26"])
        #expect(try await store.loadOlder() == nil)
    }

    @Test func insertsPendingInIDOrderAndDropsDuplicates() async throws {
        let queue = PageQueue([try page([30, 29, 28])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()
        let arrivals = try notifications([32, 31, 30])

        #expect(store.receive(arrivals[1]))
        #expect(!store.receive(arrivals[0]))
        #expect(!store.receive(arrivals[0]))
        #expect(!store.receive(arrivals[2]))

        #expect(store.flushPending().map(\.id) == ["32", "31"])
        #expect(ids(store) == ["32", "31", "30", "29", "28"])
        #expect(store.pending.isEmpty)
    }

    @Test func dropsPendingOlderThanLoadedEnd() async throws {
        let queue = PageQueue([try page([30, 29, 28])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        _ = store.receive(try notifications([20])[0])

        #expect(store.flushPending().isEmpty)
        #expect(ids(store) == ["30", "29", "28"])
    }

    /// 1ページの全部が読めなくても、読めなかった通知のIDから続きを読む。
    @Test func pageOfOnlyUnreadableNotificationsDoesNotStopLoadingOlder() async throws {
        let pages = [
            NotificationPage(notifications: [], unreadable: [30, 29, 28].map { UnreadableItem(id: String($0), url: nil) }),
            NotificationPage(notifications: try notifications([27, 26])),
        ]
        let queries = Mutex<[TimelineQuery]>([])
        let store = NotificationStore(pageSize: Self.pageSize) { query in
            queries.withLock { queries in
                queries.append(query)
                return pages[queries.count - 1]
            }
        }
        _ = try await store.loadInitial()
        #expect(store.entries.map(\.id) == ["30", "29", "28"].map { .unreadable($0) })
        #expect(!store.reachedEnd)

        #expect(try await store.loadOlder()?.map(\.id) == ["27", "26"])
        #expect(queries.withLock { $0.last } == TimelineQuery(maxID: "28", limit: Self.pageSize))
        #expect(store.entries.map(\.id) == [.unreadable("30"), .unreadable("29"), .unreadable("28"), .notification("27"), .notification("26")])
    }

    /// 読めなかった通知と同じIDの通知が届いたら、置き換える。末尾の読めなかった通知でも同じ。
    @Test(arguments: [30, 28])
    func readableNotificationReplacesUnreadable(id: Int) async throws {
        let unreadable = [30, 29, 28].filter { $0 == id }.map { UnreadableItem(id: String($0), url: nil) }
        let readable = try notifications([30, 29, 28].filter { $0 != id })
        let store = NotificationStore(pageSize: Self.pageSize) { _ in NotificationPage(notifications: readable, unreadable: unreadable) }
        _ = try await store.loadInitial()
        #expect(!store.isEmpty)

        _ = store.receive(try notifications([id])[0])
        #expect(store.flushPending().map(\.id) == [String(id)])

        #expect(store.entries.map(\.id) == ["30", "29", "28"].map { .notification($0) })
    }

    /// 満杯でないページの後に0件が返ったら、手元とつながっている。
    @Test func fillConnectsWithinOnePage() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([32, 31]), try page([])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(try await store.fillFromLatest(maxPages: 1)?.map(\.id) == ["32", "31"])

        #expect(ids(store) == ["32", "31", "30", "29", "28"])
        #expect(Array(queue.queries.suffix(2)) == [
            TimelineQuery(sinceID: "30", limit: Self.pageSize),
            TimelineQuery(maxID: "31", sinceID: "30", limit: Self.pageSize),
        ])
    }

    /// 求めた件数より少なく返すサーバーでは、満杯でないページの下にも通知が残っているため、それだけではつながったと判断しない。
    @Test func shortPageFromCappingServerIsNotTreatedAsConnected() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([36, 35]), try page([34, 33])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(try await store.fillFromLatest(maxPages: 1)?.map(\.id) == ["36", "35", "34", "33"])

        #expect(ids(store) == ["36", "35", "34", "33"], "間を欠いたまま古い通知を残しました")
        #expect(!store.reachedEnd)
    }

    @Test func fillFromEmptyWithShortPageKeepsOlderLoadable() async throws {
        let queue = PageQueue([try page([]), try page([5, 4])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        _ = try await store.fillFromLatest(maxPages: 1)

        #expect(!store.reachedEnd, "求めた件数より少ないだけで、それより古い通知がないと判断しました")
    }

    @Test func fillReadsFurtherPagesUntilConnected() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([36, 35, 34]), try page([33, 32, 31]), try page([])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(try await store.fillFromLatest(maxPages: 3)?.map(\.id) == ["36", "35", "34", "33", "32", "31"])

        #expect(ids(store) == ["36", "35", "34", "33", "32", "31", "30", "29", "28"])
        #expect(queue.queries.dropFirst().map(\.maxID) == [nil, "34", "31"])
        #expect(queue.queries.dropFirst().allSatisfy { $0.sinceID == "30" })
    }

    /// 上限まで読んでもつながらなければ、間を欠いたまま並べず、読んだ範囲より古い手元の通知を捨てる。
    @Test func fillDropsOlderNotificationsWhenNotConnected() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([27, 26, 25]), try page([40, 39, 38]), try page([37, 36, 35])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()
        _ = try await store.loadOlder()

        #expect(try await store.fillFromLatest(maxPages: 2)?.map(\.id) == ["40", "39", "38", "37", "36", "35"])

        #expect(ids(store) == ["40", "39", "38", "37", "36", "35"])
        #expect(!store.reachedEnd)
    }

    /// 補完が失敗した後に新着が挿入されても、次の補完は失敗したときの基準から読む。
    @Test func retriesFillFromSameBaseAfterFailure() async throws {
        let queue = PageQueue([try page([30, 29, 28]), .failure(Failure()), try page([40, 33, 32])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        await #expect(throws: Failure.self) { try await store.fillFromLatest(maxPages: 1) }
        _ = store.receive(try notifications([40])[0])
        _ = store.flushPending()
        _ = try await store.fillFromLatest(maxPages: 1)

        #expect(queue.queries.map(\.sinceID) == [nil, "30", "30"])
        // 1ページでつながらないため、読んだ範囲より古い手元の通知を捨てる。
        #expect(ids(store) == ["40", "33", "32"])
    }

    /// 古いページを読んでいる間に、補完が古い側を捨てて読み込む範囲を変えたら、捨てる前の末尾から読んだページは合流させない。
    /// 合流させると、補完で読んだ範囲との間が欠けたまま並び、次の`max_id`もその先へ進んで読み直せなくなるため。
    @Test func discardsOlderPageLoadedAcrossTruncatingFill() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([27, 26, 25]), try page([40, 39, 38])])
        let gate = FetchGate()
        let store = NotificationStore(pageSize: Self.pageSize) { query in
            let page = try queue.next(query)
            if query.maxID == "28" {
                await gate.wait()
            }
            return NotificationPage(notifications: page)
        }
        _ = try await store.loadInitial()

        let older = Task { try await store.loadOlder() }
        await gate.waitUntilWaiting()
        _ = try await store.fillFromLatest(maxPages: 1)
        await gate.open()

        #expect(try await older.value?.isEmpty == true)
        #expect(ids(store) == ["40", "39", "38"])
        #expect(!store.reachedEnd)
    }

    /// 1件もない状態から補完して満杯のページが返ったら、さらに古い通知があるかもしれないため、続きを読めるようにする。
    @Test func fillFromEmptyKeepsOlderLoadable() async throws {
        let queue = PageQueue([try page([]), try page([5, 4, 3]), try page([2, 1])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()
        #expect(store.reachedEnd)

        _ = try await store.fillFromLatest(maxPages: 3)

        #expect(!store.reachedEnd)
        #expect(try await store.loadOlder()?.map(\.id) == ["2", "1"])
    }

    @Test func fillWithoutAnyNotificationReadsLatestPage() async throws {
        let queue = PageQueue([try page([]), try page([2, 1])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(try await store.fillFromLatest(maxPages: 3)?.map(\.id) == ["2", "1"])
        #expect(queue.queries.last == TimelineQuery(limit: Self.pageSize))
    }

    @Test func updatesTargetStatusOfNotifications() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/alice.png"))
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: avatar)
        let target = Status(id: "100", createdAt: .now, account: account, content: "", spoilerText: "", url: nil)
        let favourite = MastodonNotification(id: "30", type: .favourite, createdAt: .now, account: account, status: target)
        let follow = try notifications([29])[0]
        let queue = PageQueue([.success([favourite, follow])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(store.updateStatus("100") { $0.settingFavourited(true) })
        #expect(store.notifications.first?.status?.favourited == true)
        #expect(!store.updateStatus("999") { $0.settingFavourited(true) })
    }

    @Test func countsUnreadNewerThanMarker() async throws {
        let queue = PageQueue([try page([30, 29, 28])])
        let store = makeStore(queue)

        _ = try await store.loadInitial(markerID: "28")

        #expect(store.unreadCount == 2)
        #expect(!store.hasUnloadedUnread)
        #expect(store.readIDToSave == nil)
        store.markRead(["29"])
        #expect(store.unreadCount == 1)
        #expect(store.readIDToSave == "29")
        store.markRead(["28"])
        #expect(store.lastReadID == "29")
        store.markSaved("29")
        #expect(store.readIDToSave == nil)
    }

    @Test func unreadIsLowerBoundWhenMarkerIsOlderThanLoaded() async throws {
        let queue = PageQueue([try page([30, 29, 28])])
        let store = makeStore(queue)

        _ = try await store.loadInitial(markerID: "10")

        #expect(store.unreadCount == 3)
        #expect(store.hasUnloadedUnread)
    }
}
