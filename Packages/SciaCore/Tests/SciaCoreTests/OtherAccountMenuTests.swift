import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// 投稿のメニューの「別のアカウントで」を確かめる。決まりはdocs/menus.mdにある。
@MainActor
struct OtherAccountMenuTests {
    private struct Failure: Error {}

    private let uri = "https://remote.example/users/alice/statuses/1"
    private let alice = Account(id: "1", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil)

    /// 今のアカウントのサーバーでの投稿。
    private func status(id: String = "100", uri: String?, favourited: Bool = false, visibility: Status.Visibility = .public) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 100), account: alice, content: "<p>こんにちは</p>", spoilerText: "", uri: uri, url: nil, visibility: visibility, favourited: favourited)
    }

    private func credential(_ username: String, server: String = "other.example", accountID: String = "50") throws -> Credential {
        Credential(instance: try #require(URL(string: "https://\(server)")), accessToken: "token", clientID: "id", clientSecret: "secret", accountID: accountID, username: username)
    }

    private func operations(search: @escaping @Sendable (String) async throws -> [Status], favourite: @escaping @Sendable (Status.ID) async throws -> Status = { _ in throw Failure() }) -> OtherAccountStatuses.Operations {
        OtherAccountStatuses.Operations(search: search, interactions: StatusInteractions.Operations(
            favourite: favourite,
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() }
        ))
    }

    private func account(_ username: String, server: String = "other.example", accountID: String = "50", _ operations: OtherAccountStatuses.Operations) throws -> OtherAccountStatuses {
        OtherAccountStatuses(credential: try credential(username, server: server, accountID: accountID), operations: operations, tasks: TaskScope())
    }

    private func tree(_ status: Status, accounts: [OtherAccountStatuses], groups: MenuLayout<StatusMenuItem>.Groups = StatusMenuItem.defaultLayout.groups) -> StatusMenuTree {
        var tree = StatusMenuTree(status: status, notification: nil, now: Date(timeIntervalSince1970: 0), linkBrowser: .inApp)
        tree.myAccountID = "9"
        tree.otherAccounts = accounts
        tree.otherAccountGroups = groups
        return tree
    }

    /// 「別のアカウントで」の項目だけを組んだもの。
    private func node(_ tree: StatusMenuTree) -> MenuNode<StatusMenuCommand>? {
        tree.menu(groups: .single(.otherAccounts), includesFollowRequest: false).root?.flattenedChildren.first
    }

    /// 開いてから読む中身を読み、文字にする。
    private func loaded(_ nodes: [MenuNode<StatusMenuCommand>]) async -> String {
        var described: [String] = []
        for node in nodes {
            if case .deferred(let load) = node.content {
                described.append(MenuNodeTests.describe(await load()))
            } else {
                described.append(MenuNodeTests.describe([node]))
            }
        }
        return described.joined(separator: "|")
    }

    /// ほかのアカウントがなければ出さない。1つなら「@usernameで」を直に置き、2つ以上ならアカウントごとのサブメニューを並べる。サーバー名はサブタイトルに出す。
    /// 探していない投稿は、開いてから探す。
    @Test func listsOtherAccountsBySubmenu() throws {
        let search: @Sendable (String) async throws -> [Status] = { _ in [] }
        let bob = try account("bob", operations(search: search))
        let carol = try account("carol", server: "third.example", operations(search: search))

        #expect(node(tree(status(uri: uri), accounts: [])) == nil)
        let single = try #require(node(tree(status(uri: uri), accounts: [bob])))
        #expect(MenuNodeTests.describe([single]) == "@bobで[…]")
        #expect(single.subtitle == "other.example")
        let both = try #require(node(tree(status(uri: uri), accounts: [bob, carol])))
        #expect(MenuNodeTests.describe([both]) == "別のアカウントで[@bob[…],@carol[…]]")
        #expect(both.children.map(\.subtitle) == ["other.example", "third.example"])
    }

    /// 選んだアカウントのサーバーで、URIが同じ投稿を探し、そのアカウントから見た状態で項目を組む。
    /// 押した操作は、そのサーバーでの投稿のIDで、そのアカウントとして行う。見つけた投稿は覚え、次はすぐ組む。
    @Test func buildsItemsFromStatusFoundOnOtherServer() async throws {
        let uri = uri
        let other = status(id: "7000", uri: uri, favourited: true)
        // 検索はURIに近いほかの投稿も返すことがある。
        let near = status(id: "6999", uri: "https://remote.example/users/alice/statuses/2")
        let queries = Mutex<[String]>([])
        let bob = try account("bob", operations { query in
            queries.withLock { $0.append(query) }
            return [near, other]
        })
        let menu = try #require(node(tree(status(uri: uri), accounts: [bob])))

        #expect(await loaded(menu.children) == "=ブースト,お気に入りを取り消す|ブックマーク")
        #expect(queries.withLock { $0 } == [uri])

        let reopened = try #require(node(tree(status(uri: uri), accounts: [bob])))
        #expect(MenuNodeTests.describe(reopened.children) == "=ブースト,お気に入りを取り消す|ブックマーク")
        let favourite = try #require(reopened.flattenedChildren.first { $0.title == "お気に入りを取り消す" })
        guard case .otherAccount(let command) = favourite.command else {
            Issue.record("ほかのアカウントの操作になっていません")
            return
        }
        #expect(command.status.id == "7000")
        #expect(command.account === bob)
        guard case .favourite = command.action else {
            Issue.record("お気に入りの操作になっていません")
            return
        }
    }

    /// 中身は渡した並びに従い、そのアカウントで送るだけで済む項目だけを出す。「その他」に入れた項目も、まとめずに続けて並べる。
    @Test func followsGivenLayoutWithoutMoreSubmenu() async throws {
        let found = status(id: "7000", uri: uri)
        let bob = try account("bob", operations { _ in [found] })
        let groups = MenuLayout<StatusMenuItem>.Groups(
            main: [.init([.favourite, .reply, .reblogWithVisibility])],
            more: [.init([.bookmark, .delete, .customize])]
        )
        let menu = try #require(node(tree(status(uri: uri), accounts: [bob], groups: groups)))

        let items = await loaded(menu.children)
        #expect(items == "お気に入り,公開範囲を選んでブースト[公開,ひかえめな公開,フォロワーのみ]|ブックマーク")
    }

    /// そのアカウントから見られない投稿と、探せなかったときは、押せない行で知らせる。URIのない投稿は探さない。
    @Test func reportsStatusesThatCannotBeFound() async throws {
        let calls = Mutex(0)
        let notFound = try account("bob", operations { _ in
            calls.withLock { $0 += 1 }
            return []
        })
        let failing = try account("bob", operations { _ in throw Failure() })

        #expect(await loaded(try #require(node(tree(status(uri: uri), accounts: [notFound]))).children) == "このアカウントからは見られない投稿です(押せない)")
        #expect(await loaded(try #require(node(tree(status(uri: nil), accounts: [notFound]))).children) == "このアカウントからは見られない投稿です(押せない)")
        #expect(calls.withLock { $0 } == 1)
        #expect(await loaded(try #require(node(tree(status(uri: uri), accounts: [failing]))).children) == "投稿を探せませんでした(押せない)")
    }

    /// 見つけたあとに見られなくなった投稿は忘れ、次に開いたときは探し直す。
    @Test func forgetsStatusThatIsNoLongerFound() async throws {
        let found = status(id: "7000", uri: uri)
        let isVisible = Mutex(true)
        let bob = try account("bob", operations { _ in
            isVisible.withLock { $0 } ? [found] : []
        })
        let shown = status(uri: uri)

        _ = await bob.lookup(shown)
        #expect(bob.known(shown)?.id == "7000")
        isVisible.withLock { $0 = false }
        _ = await bob.lookup(shown)
        #expect(bob.known(shown) == nil)
    }

    /// 操作の結果は、そのアカウントで覚えている投稿に反映し、次に開いたメニューの名前に出る。
    @Test func toggleUpdatesKnownStatus() async throws {
        let found = status(id: "7000", uri: uri)
        let bob = try account("bob", operations(search: { _ in [found] }, favourite: { _ in found.settingFavourited(true) }))
        let shown = status(uri: uri)
        guard case .found(let resolved) = await bob.lookup(shown) else {
            Issue.record("投稿が見つかりません")
            return
        }

        #expect(try await bob.toggle(.favourite, on: resolved))
        #expect(bob.known(shown)?.favourited == true)
        #expect(MenuNodeTests.describe(try #require(node(tree(shown, accounts: [bob]))).children).contains("お気に入りを取り消す"))
    }

    /// ブーストできるかは、そのアカウントで決める。フォロワーのみの投稿は、書いた人のアカウントからだけブーストできる。
    @Test func decidesReblogAsOtherAccount() async throws {
        let found = status(id: "7000", uri: uri, visibility: .private)
        let author = try account("alice", accountID: "1", operations { _ in [found] })
        let menu = try #require(node(tree(status(uri: uri, visibility: .private), accounts: [author])))

        #expect(await loaded(menu.children) == "=ブースト,お気に入り|ブックマーク")
    }

    /// メニューを開いたときの探し直しが、そのあとの操作より遅れて届いても、操作の結果を探す前の状態に戻さない。
    @Test func lateRefreshDoesNotUndoToggle() async throws {
        let found = status(id: "7000", uri: uri)
        let refreshing = Gate()
        let searches = Mutex(0)
        let bob = try account("bob", operations(search: { _ in
            let count = searches.withLock { count in
                count += 1
                return count
            }
            // 2回目は、操作の前の状態を読んだあと、届くのを遅らせる。
            if count > 1 { try await refreshing.wait() }
            return [found]
        }, favourite: { _ in found.settingFavourited(true) }))
        let shown = status(uri: uri)
        _ = await bob.lookup(shown)

        let refresh = Task { await bob.lookup(shown) }
        try await waitUntil { refreshing.waiterCount == 1 }
        #expect(try await bob.toggle(.favourite, on: found))
        refreshing.open()
        guard case .found(let afterRefresh) = await refresh.value else {
            Issue.record("投稿が見つかりません")
            return
        }

        #expect(afterRefresh.favourited)
        #expect(bob.known(shown)?.favourited == true)
    }

    /// 同じ投稿を探している間に探し直しても、検索を送り直さずに同じ結果を待つ。
    @Test func sharesRunningSearch() async throws {
        let found = status(id: "7000", uri: uri)
        let responding = Gate()
        let searches = Mutex(0)
        let bob = try account("bob", operations { _ in
            searches.withLock { $0 += 1 }
            try await responding.wait()
            return [found]
        })
        let shown = status(uri: uri)

        let first = Task { await bob.lookup(shown) }
        try await waitUntil { responding.waiterCount == 1 }
        let second = Task { await bob.lookup(shown) }
        responding.open()
        _ = await first.value
        guard case .found = await second.value else {
            Issue.record("投稿が見つかりません")
            return
        }
        #expect(searches.withLock { $0 } == 1)
    }

    /// 前に見つけた投稿を探し直せなかったときは、覚えている投稿のまま使う。
    @Test func keepsKnownStatusWhenRefreshFails() async throws {
        let found = status(id: "7000", uri: uri)
        let fails = Mutex(false)
        let bob = try account("bob", operations { _ in
            if fails.withLock({ $0 }) { throw Failure() }
            return [found]
        })
        let shown = status(uri: uri)
        _ = await bob.lookup(shown)
        fails.withLock { $0 = true }

        guard case .found = await bob.lookup(shown) else {
            Issue.record("覚えている投稿が使われません")
            return
        }
        #expect(bob.known(shown)?.id == "7000")
    }
}
