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

    /// 読み込み中の表示に使う。つながったかが分かるまで並べないので、読んだ通知の数を1ページごとに積み上げて渡す。
    @Test func fillReportsReadCountPerPage() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([36, 35, 34]), try page([33, 32, 31]), try page([])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()
        var reported: [Int] = []

        _ = try await store.fillFromLatest(maxPages: 3) { reported.append($0) }

        #expect(reported == [3, 6])
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

    /// 削除した投稿についての通知を除き、ほかの通知は残す。
    @Test func removesNotificationsAboutDeletedStatus() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/alice.png"))
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: avatar)
        let target = Status(id: "100", createdAt: .now, account: account, content: "", spoilerText: "", url: nil)
        let favourite = MastodonNotification(id: "30", type: .favourite, createdAt: .now, account: account, status: target)
        let follow = try notifications([29])[0]
        let queue = PageQueue([.success([favourite, follow])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(store.removeStatus("100"))
        #expect(ids(store) == ["29"])
        #expect(!store.removeStatus("100"))
    }

    /// ミュートかブロックした相手からの通知を除き、あとから届いても足さない。解除したら、また足す。
    @Test func excludeAccountRemovesItsNotificationsUntilIncluded() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/carol.png"))
        let carol = Account(id: "9", username: "carol", acct: "carol", displayName: "Carol", avatar: avatar)
        func carols(_ id: Int) -> MastodonNotification {
            MastodonNotification(id: String(id), type: .follow, createdAt: Date(timeIntervalSince1970: TimeInterval(id)), account: carol, status: nil)
        }
        let queue = PageQueue([.success([carols(30)] + (try notifications([29])))])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(store.excludeAccount("9"))
        #expect(ids(store) == ["29"])
        #expect(!store.receive(carols(31)))

        store.includeAccount("9")
        #expect(store.receive(carols(32)))
    }

    /// 古いページを読んでいる間にミュートかブロックをして、届いたページが全部その人の通知でも、ページの一番古い通知の先から続きを読む。
    @Test func olderPageOfExcludedAccountStillAdvances() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/carol.png"))
        let carol = Account(id: "9", username: "carol", acct: "carol", displayName: "Carol", avatar: avatar)
        let carols = [29, 28, 27].map { MastodonNotification(id: String($0), type: .follow, createdAt: Date(timeIntervalSince1970: TimeInterval($0)), account: carol, status: nil) }
        let gate = PageGate(NotificationPage(notifications: carols))
        let queries = Mutex<[String?]>([])
        let initial = try notifications([30])
        let older = try notifications([26])
        let store = NotificationStore(pageSize: Self.pageSize) { query in
            queries.withLock { $0.append(query.maxID) }
            switch query.maxID {
            case nil: return NotificationPage(notifications: initial)
            case "30": return await gate.fetch()
            case "27": return NotificationPage(notifications: older)
            default: return NotificationPage(notifications: [])
            }
        }
        _ = try await store.loadInitial()
        await gate.hold()
        let read = Task { try await store.loadOlder() }
        await gate.waitForRequest()

        store.excludeAccount("9")
        await gate.release()
        _ = try await read.value

        #expect(ids(store) == ["30", "26"])
        #expect(queries.withLock { $0 } == [nil, "30", "27"])
    }

    /// 削除の前に読み始めたページや、遅れて届いた通知で、削除した投稿についての通知を戻さない。
    @Test func deletedStatusNotificationsDoNotReturn() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/alice.png"))
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: avatar)
        let target = Status(id: "100", createdAt: .now, account: account, content: "", spoilerText: "", url: nil)
        let favourite = MastodonNotification(id: "31", type: .favourite, createdAt: .now, account: account, status: target)
        let queue = PageQueue([try page([29]), .success([favourite] + (try notifications([30]))), try page([])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        store.removeStatus("100")
        #expect(!store.receive(favourite))
        _ = try await store.fillFromLatest(maxPages: 1)

        #expect(ids(store) == ["30", "29"])
    }

    /// 削除の前に読み始めた古いページが、削除のあとに届いても、削除した投稿についての通知を戻さない。
    @Test func deletedStatusNotificationsDoNotReturnFromReadStartedBefore() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/alice.png"))
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: avatar)
        let target = Status(id: "100", createdAt: .now, account: account, content: "", spoilerText: "", url: nil)
        let older = MastodonNotification(id: "200", type: .favourite, createdAt: .now, account: account, status: target)
        let newer = MastodonNotification(id: "300", type: .favourite, createdAt: .now, account: account, status: target)
        let gate = PageGate(NotificationPage(notifications: [older]))
        // 届いたページの通知が全部除かれても、その先を読みに行く。その先は空にして、読み終える。
        let store = NotificationStore(pageSize: 40) { query in
            switch query.maxID {
            case nil: NotificationPage(notifications: [newer])
            case "300": await gate.fetch()
            default: NotificationPage(notifications: [])
            }
        }
        _ = try await store.loadInitial()
        await gate.hold()
        let read = Task { try await store.loadOlder() }
        await gate.waitForRequest()

        #expect(store.removeStatus("100"))
        await gate.release()
        _ = try await read.value

        #expect(store.notifications.isEmpty)
    }

    /// 承認か却下で片づけたら、そのユーザーからのフォローリクエストの通知だけを除き、同じユーザーのほかの通知は残す。
    /// 片づける前に読み始めた補完や、遅れて届いた通知でも戻さない。
    @Test func removesResolvedFollowRequestsFromAccount() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/alice.png"))
        let alice = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: avatar)
        let request = MastodonNotification(id: "30", type: .followRequest, createdAt: .now, account: alice)
        let otherRequest = MastodonNotification(id: "29", type: .followRequest, createdAt: .now, account: try notifications([29])[0].account)
        let follow = MastodonNotification(id: "28", type: .follow, createdAt: .now, account: alice)
        let queue = PageQueue([.success([request, otherRequest, follow]), .success([request]), .success([])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(store.removeFollowRequests(answering: request))
        #expect(ids(store) == ["29", "28"])
        #expect(!store.removeFollowRequests(answering: request))
        #expect(!store.receive(request))
        _ = try await store.fillFromLatest(maxPages: 1)

        #expect(ids(store) == ["29", "28"])
    }

    /// 削除した通知は一覧から除き、削除の前に読み始めた補完やストリーミングでも戻さない。
    @Test func removedNotificationDoesNotReturn() async throws {
        let all = try notifications([30, 29, 28])
        let queue = PageQueue([.success(all), .success([all[1]]), .success([])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()

        #expect(store.removeNotification("29"))
        #expect(ids(store) == ["30", "28"])
        #expect(!store.removeNotification("29"))
        #expect(!store.receive(all[1]))
        _ = try await store.fillFromLatest(maxPages: 1)

        #expect(ids(store) == ["30", "28"])
    }

    /// 削除の応答を待つ間に、補完で一覧から外れた通知が、古いページで読めなかった行として入っても、削除できたら除く。
    @Test func removedNotificationAlsoRemovesItsUnreadableRow() async throws {
        let pages = [
            NotificationPage(notifications: try notifications([30, 29, 28])),
            NotificationPage(notifications: try notifications([40, 39, 38])),
            NotificationPage(notifications: try notifications([37, 36]), unreadable: [UnreadableItem(id: "29", url: nil)]),
        ]
        let count = Mutex(0)
        let store = NotificationStore(pageSize: Self.pageSize) { _ in
            count.withLock { count in
                count += 1
                return pages[count - 1]
            }
        }
        _ = try await store.loadInitial()
        _ = try await store.fillFromLatest(maxPages: 1)
        _ = try await store.loadOlder()
        #expect(store.unreadable.map(\.id) == ["29"])

        #expect(store.removeNotification("29"))
        #expect(store.unreadable.isEmpty)
    }

    /// 応答を待つ間に補完が古い側を捨てて、片づけた通知が一覧から外れていても、そのあと読んだ古いページで戻さない。
    @Test func resolvedFollowRequestDoesNotReturnAfterTruncatingFill() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/alice.png"))
        let alice = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: avatar)
        let request = MastodonNotification(id: "30", type: .followRequest, createdAt: .now, account: alice)
        let initial = NotificationPage(notifications: [request] + (try notifications([29, 28])))
        let latest = NotificationPage(notifications: try notifications([40, 39, 38]))
        let older = PageGate(NotificationPage(notifications: try notifications([37, 36]) + [request]))
        let store = NotificationStore(pageSize: Self.pageSize) { query in
            if query.sinceID != nil { return latest }
            if query.maxID != nil { return await older.fetch() }
            return initial
        }
        _ = try await store.loadInitial()
        _ = try await store.fillFromLatest(maxPages: 1)
        #expect(ids(store) == ["40", "39", "38"])
        await older.hold()
        let read = Task { try await store.loadOlder() }
        await older.waitForRequest()

        store.removeFollowRequests(answering: request)
        await older.release()
        _ = try await read.value

        #expect(ids(store) == ["40", "39", "38", "37", "36"])
    }

    /// 片づけたフォローリクエストの通知が、あとのページで読めなかったときも、読めなかった行として戻さない。
    @Test func resolvedFollowRequestDoesNotReturnAsUnreadable() async throws {
        let avatar = try #require(URL(string: "https://example.social/avatars/alice.png"))
        let alice = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: avatar)
        let request = MastodonNotification(id: "30", type: .followRequest, createdAt: .now, account: alice)
        let pages = [
            NotificationPage(notifications: [request] + (try notifications([29]))),
            NotificationPage(notifications: [], unreadable: [UnreadableItem(id: "30", url: nil)]),
            NotificationPage(notifications: []),
        ]
        let count = Mutex(0)
        let store = NotificationStore(pageSize: Self.pageSize) { _ in
            count.withLock { count in
                count += 1
                return pages[count - 1]
            }
        }
        _ = try await store.loadInitial()

        store.removeFollowRequests(answering: request)
        _ = try await store.fillFromLatest(maxPages: 1)

        #expect(store.entries.map(\.id) == [.notification("29")])
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

    #if DEBUG
    /// サーバーにない検証用の通知は、見れば手元では既読にするが、サーバーに保存する既読位置には使わない。
    @Test func debugLocalOnlyNotificationIsReadLocallyButNotSaved() async throws {
        let queue = PageQueue([try page([30, 29, 28])])
        let store = makeStore(queue)
        _ = try await store.loadInitial(markerID: "30")
        store.debugLocalOnlyIDs.insert("99")
        _ = store.receive(try notifications([99])[0])
        _ = store.flushPending()

        #expect(store.unreadCount == 1)
        store.markRead(["99", "30"])

        #expect(store.unreadCount == 0)
        #expect(store.readIDToSave == nil)
    }

    /// 補完はサーバーにない検証用の通知より後ではなく、サーバーから読んだ最も新しい通知より後を読む。
    /// 検証用の通知のIDは手元の最新より大きいため、それを基準にすると、切れていた間に届いた本物の通知を読み落とす。
    @Test func fillIgnoresDebugLocalOnlyNotifications() async throws {
        let queue = PageQueue([try page([30, 29, 28]), try page([31]), try page([])])
        let store = makeStore(queue)
        _ = try await store.loadInitial()
        store.debugLocalOnlyIDs.insert("99")
        _ = store.receive(try notifications([99])[0])
        _ = store.flushPending()

        #expect(try await store.fillFromLatest(maxPages: 1)?.map(\.id) == ["31"])
        #expect(queue.queries.dropFirst().first?.sinceID == "30")
    }
    #endif
}
