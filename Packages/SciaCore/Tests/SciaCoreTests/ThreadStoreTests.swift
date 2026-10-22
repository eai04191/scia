import Foundation
import Testing
@testable import SciaCore

/// スレッドの画面に、会話を平らに深さ優先で並べることと、開いている間に届いた返信、編集、削除を反映することを確かめる。
@MainActor
struct ThreadStoreTests {
    private let alice = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)
    private let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)

    private func status(_ id: Int, replyingTo parentID: Int? = nil, content: String = "", reblog: Status? = nil) -> Status {
        Status(
            id: String(id),
            createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
            account: id.isMultiple(of: 2) ? bob : alice,
            content: content,
            spoilerText: "",
            url: nil,
            inReplyToId: parentID.map(String.init),
            inReplyToAccountId: parentID.map { $0.isMultiple(of: 2) ? bob.id : alice.id },
            reblog: reblog
        )
    }

    private func ids(_ store: ThreadStore) -> [String] {
        store.entries.compactMap(\.status?.id)
    }

    /// 1 ← 2（押した投稿） ← 3 ← 5、2 ← 4、1 ← 6。
    private func loadedStore() -> ThreadStore {
        let store = ThreadStore(focus: status(2, replyingTo: 1))
        store.apply(StatusContext(
            ancestors: [status(1)],
            descendants: [status(4, replyingTo: 2), status(3, replyingTo: 2), status(5, replyingTo: 3)]
        ))
        return store
    }

    @Test func showsOnlyFocusBeforeLoading() {
        #expect(ids(ThreadStore(focus: status(2, replyingTo: 1))) == ["2"])
    }

    @Test func ordersRepliesDepthFirstOldestFirst() {
        #expect(ids(loadedStore()) == ["1", "2", "3", "5", "4"])
    }

    @Test func addsStreamedReplyAfterItsParentsSubtree() {
        let store = loadedStore()
        #expect(store.receive(.update(status(7, replyingTo: 3))))
        #expect(ids(store) == ["1", "2", "3", "5", "7", "4"])
    }

    @Test func placesStreamedReplyToAncestorAboveFocus() {
        let store = loadedStore()
        #expect(store.receive(.update(status(7, replyingTo: 1))))
        #expect(ids(store) == ["1", "7", "2", "3", "5", "4"])
    }

    @Test func ignoresStreamedPostsOutsideThreadAndBoosts() {
        let store = loadedStore()
        #expect(!store.receive(.update(status(7, replyingTo: 99))))
        #expect(!store.receive(.update(status(9))))
        #expect(!store.receive(.update(status(11, reblog: status(7, replyingTo: 3)))))
        #expect(ids(store) == ["1", "2", "3", "5", "4"])
    }

    @Test func appliesEditsAndDeletes() {
        let store = loadedStore()
        #expect(store.receive(.statusUpdate(status(5, replyingTo: 3, content: "編集した"))))
        #expect(store.entries.compactMap(\.status).first { $0.id == "5" }?.content == "編集した")
        #expect(store.receive(.delete(statusID: "3")))
        // 返信先が消えた返信は、最後に並べる。
        #expect(ids(store) == ["1", "2", "4", "5"])
        #expect(!store.receive(.update(status(3, replyingTo: 2))))
    }

    @Test func keepsRepliesStreamedBeforeLoading() {
        let store = ThreadStore(focus: status(2, replyingTo: 1))
        #expect(store.receive(.update(status(7, replyingTo: 2))))
        store.apply(StatusContext(ancestors: [status(1)], descendants: [status(3, replyingTo: 2)]))
        #expect(ids(store) == ["1", "2", "3", "7"])
    }

    @Test func addsReplyToMeArrivingOnlyAsMentionNotification() {
        let store = loadedStore()
        let reply = status(7, replyingTo: 5)
        let mention = MastodonNotification(id: "n1", type: .mention, createdAt: reply.createdAt, account: reply.account, status: reply)
        #expect(store.receive(.notification(mention)))
        #expect(ids(store) == ["1", "2", "3", "5", "7", "4"])
    }

    @Test func reloadDropsPostsDeletedWhileDisconnected() {
        let store = loadedStore()
        #expect(store.receive(.update(status(7, replyingTo: 3))))
        store.beginLoading()
        // 切れている間に4と7が消え、読み直した会話に含まれない。
        store.apply(StatusContext(ancestors: [status(1)], descendants: [status(3, replyingTo: 2), status(5, replyingTo: 3)]))
        #expect(ids(store) == ["1", "2", "3", "5"])
    }

    @Test func keepsReplyStreamedWhileReloading() {
        let store = loadedStore()
        store.beginLoading()
        #expect(store.receive(.update(status(7, replyingTo: 3))))
        store.apply(StatusContext(ancestors: [status(1)], descendants: [status(3, replyingTo: 2), status(5, replyingTo: 3), status(4, replyingTo: 2)]))
        #expect(ids(store) == ["1", "2", "3", "5", "7", "4"])
    }

    @Test func reloadKeepsEditsReceivedWhileLoading() {
        let store = loadedStore()
        store.beginLoading()
        #expect(store.receive(.statusUpdate(status(3, replyingTo: 2, content: "編集した"))))
        #expect(store.receive(.statusUpdate(status(2, replyingTo: 1, content: "押した投稿を編集した"))))
        // 読み始めた時点の、編集前の応答が後から届く。
        store.apply(
            StatusContext(ancestors: [status(1)], descendants: [status(3, replyingTo: 2), status(5, replyingTo: 3), status(4, replyingTo: 2)]),
            focus: status(2, replyingTo: 1)
        )
        let contents = Dictionary(uniqueKeysWithValues: store.entries.compactMap(\.status).map { ($0.id, $0.content) })
        #expect(contents["3"] == "編集した")
        #expect(contents["2"] == "押した投稿を編集した")
    }

    @Test func reloadTakesEditedFocus() {
        let store = loadedStore()
        store.beginLoading()
        store.apply(StatusContext(ancestors: [status(1)], descendants: []), focus: status(2, replyingTo: 1, content: "編集した"))
        #expect(store.entries.compactMap(\.status).first { $0.id == "2" }?.content == "編集した")
    }

    @Test func hidesPostsMatchingHideFilterExceptFocus() {
        let hide = FilterResult(filter: FilterResult.Filter(id: "f", title: "隠す", context: [.thread], filterAction: .hide), keywordMatches: ["x"])
        func filtered(_ status: Status) -> Status {
            Status(id: status.id, createdAt: status.createdAt, account: status.account, content: "", spoilerText: "", url: nil,
                   inReplyToId: status.inReplyToId, inReplyToAccountId: status.inReplyToAccountId, filtered: [hide])
        }
        let store = ThreadStore(focus: filtered(status(2, replyingTo: 1)), filtering: StatusFiltering(context: .thread, myAccountID: "9"))
        store.apply(StatusContext(ancestors: [status(1)], descendants: [filtered(status(3, replyingTo: 2)), status(5, replyingTo: 3)]))
        #expect(ids(store) == ["1", "2", "5"])
    }

    @Test func readsContextSkippingUnreadableStatuses() async throws {
        let transport = StubTransport([try .fixture("status_context")])
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

        let context = try await client.statusContext("113000000000000002")

        #expect(await transport.requests.first?.url?.path() == "/api/v1/statuses/113000000000000002/context")
        #expect(context.ancestors.map(\.id) == ["113000000000000001"])
        #expect(context.descendants.map(\.id) == ["113000000000000003"])
    }
}
