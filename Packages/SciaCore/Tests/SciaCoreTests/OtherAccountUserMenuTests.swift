import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// ユーザーのメニューの「別のアカウントで」を確かめる。決まりはdocs/other-accounts.mdにある。
@MainActor
struct OtherAccountUserMenuTests {
    private struct Failure: Error {}

    private static let aliceURL = URL(string: "https://remote.example/@alice")
    /// 今のアカウントのサーバーでの相手。
    private let alice = Account(id: "1", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil, url: aliceURL)
    /// ほかのアカウントのサーバーでの、同じ相手。
    private let otherAlice = Account(id: "500", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil, url: aliceURL)

    private func account(
        _ username: String = "bob",
        search: @escaping @Sendable (String) async throws -> [Status] = { _ in [] },
        resolveAccount: @escaping @Sendable (URL) async throws -> Account? = { _ in nil },
        relationships: @escaping RelationshipCache.Fetch = { ids in ids.map { Relationship(id: $0) } }
    ) throws -> OtherAccount {
        let credential = Credential(instance: try #require(URL(string: "https://other.example")), accessToken: "token", clientID: "id", clientSecret: "secret", accountID: "50", username: username)
        let operations = OtherAccount.Operations(
            search: search,
            interactions: StatusInteractions.Operations(
                favourite: { _ in throw Failure() }, unfavourite: { _ in throw Failure() },
                reblog: { _, _ in throw Failure() }, unreblog: { _ in throw Failure() },
                bookmark: { _ in throw Failure() }, unbookmark: { _ in throw Failure() },
                muteConversation: { _ in throw Failure() }, unmuteConversation: { _ in throw Failure() },
                pin: { _ in throw Failure() }, unpin: { _ in throw Failure() },
                addEmojiReaction: { _, _ in throw Failure() }, removeEmojiReaction: { _, _ in throw Failure() }
            ),
            profile: { throw Failure() },
            relationships: relationships,
            changeRelation: { _, _ in throw Failure() },
            resolveAccount: resolveAccount,
            deleteStatus: { _ in throw Failure() },
            capabilities: { throw Failure() }
        )
        return OtherAccount(credential: credential, operations: operations, tasks: TaskScope())
    }

    private func actions(_ accounts: [OtherAccount]) -> UserMenuActions {
        UserMenuActions(
            mention: { _ in }, copy: { _, _, _ in }, localServer: "example.social",
            resolveTarget: { _ in throw CancellationError() }, loadRelation: { _, _ in nil }, knownRelation: { _ in nil }, reloadRelations: { _ in },
            changeRelation: { _, _ in }, editNote: { _ in }, report: { _, _, _ in }, addToList: { _ in }, accounts: AccountCache { _ in [] },
            otherAccounts: { accounts }
        )
    }

    private let groups = MenuLayout<UserMenuItem>.Groups(main: [.init([.profile, .copyHandle, .mention, .addToList]), .init([.follow, .mute]), .init([.otherAccounts])], more: [])

    /// `user`のユーザーのメニューの「別のアカウントで」の項目。
    private func otherAccountsNode(_ user: Account? = nil, accounts: [OtherAccount]) -> MenuNode<UserMenuCommand>? {
        var tree = UserMenuTree(subject: UserMenuSubject(.account(user ?? alice)), actions: actions(accounts), linkBrowser: .inApp)
        // タップや長押しに割り当てたときのように「別のアカウントで」だけを組んでも、中身はユーザーのメニューの並びで組む。
        tree.otherAccountGroups = groups
        return tree.menu(groups: .single(.otherAccounts), avatar: nil)?.flattenedChildren.first
    }

    /// 開いてから読む中身を、中の読み込みも含めて読む。
    private func loaded(_ nodes: [MenuNode<UserMenuCommand>]) async -> [MenuNode<UserMenuCommand>] {
        var result: [MenuNode<UserMenuCommand>] = []
        for node in nodes {
            switch node.content {
            case .deferred(let load): result += await loaded(await load())
            case .group(let children, let isRow): result.append(.group(await loaded(children), isRow: isRow))
            default: result.append(node)
            }
        }
        return result
    }

    /// ほかのアカウントがなければ出さない。1つなら「@usernameで」を直に置き、2つ以上ならアカウントごとのサブメニューを並べる。
    /// プロフィールのURLのない人は、ほかのサーバーで探せないので出さない。
    @Test func listsOtherAccounts() throws {
        let bob = try account("bob")
        let carol = try account("carol")

        #expect(otherAccountsNode(accounts: []) == nil)
        #expect(otherAccountsNode(Account(id: "2", username: "dave", acct: "dave", displayName: "", avatar: nil, url: nil), accounts: [bob]) == nil)
        let single = try #require(otherAccountsNode(accounts: [bob]))
        #expect(MenuNodeTests.describe([single]) == "@bobで[…]")
        #expect(single.subtitle == "other.example")
        let both = try #require(otherAccountsNode(accounts: [bob, carol]))
        #expect(MenuNodeTests.describe([both]) == "別のアカウントで[@bob[…],@carol[…]]")
    }

    /// 選んだアカウントのサーバーでプロフィールのURLで相手を探し、そのアカウントから見た関係で項目を組む。どのアカウントでも同じ結果になる項目と、「別のアカウントで」は出さない。
    /// 見つけた相手は覚え、次はすぐ組む。
    @Test func buildsUserMenuAsOtherAccount() async throws {
        let otherAlice = otherAlice
        let resolved = Mutex<[URL]>([])
        let bob = try account(resolveAccount: { url in
            resolved.withLock { $0.append(url) }
            return otherAlice
        }, relationships: { ids in ids.map { Relationship(id: $0, following: true) } })
        let tree = UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: actions([bob]), linkBrowser: .inApp)
        let menu = try #require(tree.menu(groups: groups, avatar: nil))
        let bobMenu = try #require(menu.flattenedChildren.first { $0.title == "@bobで" })

        let items = await loaded(bobMenu.children)
        #expect(MenuNodeTests.describe(items) == "メンション,リストに追加|フォローを外す,ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日]")
        let unfollow = try #require(items.flatMap(\.flattenedChildren).first { $0.title == "フォローを外す" })
        guard case .otherAccount(let actor, .relation(.unfollow, let relation)) = unfollow.command else {
            Issue.record("ほかのアカウントとしてフォローを外す命令になっていません")
            return
        }
        #expect(actor === bob)
        #expect(relation.accountID == "500")
        #expect(resolved.withLock { $0 } == [Self.aliceURL].compactMap(\.self))

        // 見つけた相手と関係を覚えているので、次は探さずにすぐ組む。
        let again = try #require(tree.menu(groups: groups, avatar: nil)?.flattenedChildren.first { $0.title == "@bobで" })
        #expect(MenuNodeTests.describe(again.children) == "メンション,リストに追加|フォローを外す,ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日]")
        #expect(resolved.withLock { $0.count } == 1)
    }

    /// 既定の並びで「別のアカウントで」を出したときも、どのアカウントでも同じ結果になる項目のほかをすべて出す。
    @Test func buildsWholeDefaultLayout() async throws {
        let otherAlice = otherAlice
        let bob = try account(resolveAccount: { _ in otherAlice })
        let layout = UserMenuItem.defaultLayout.groups
        var tree = UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: actions([bob]), linkBrowser: .inApp)
        tree.otherAccountGroups = layout
        let menu = try #require(tree.menu(groups: .single(.otherAccounts), avatar: nil)?.flattenedChildren.first)
        #expect(MenuNodeTests.describe(await loaded(menu.children)) == "メンション|フォロー,リストに追加|ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日],ブロック!,通報|メモを追加")
    }

    /// メンションとリストに追加は、そのアカウントのサーバーでの相手のIDとハンドルで行う。
    @Test func mentionAndListUseIDsOnOtherServer() async throws {
        let otherAlice = otherAlice
        let bob = try account(resolveAccount: { _ in otherAlice })
        let node = try #require(otherAccountsNode(accounts: [bob]))
        let items = await loaded(node.children).flatMap(\.flattenedChildren)
        func action(_ title: String) throws -> OtherAccountUserAction {
            let item = try #require(items.first { $0.title == title })
            guard case .otherAccount(_, let action) = item.command else { throw Failure() }
            return action
        }
        guard case .addToList(let id, let acct) = try action("リストに追加") else {
            Issue.record("リストに追加の命令になっていません")
            return
        }
        #expect(id == "500")
        #expect(acct == "alice@remote.example")
        guard case .mention(let mentioned) = try action("メンション") else {
            Issue.record("メンションの命令になっていません")
            return
        }
        #expect(mentioned == "alice@remote.example")
    }

    /// 見つからなければ押せない行で知らせ、探せなければ理由を添えて押せない行で知らせる。
    @Test func showsWhenPersonIsNotFound() async throws {
        let notFound = try #require(otherAccountsNode(accounts: [try account(resolveAccount: { _ in nil })]))
        #expect(MenuNodeTests.describe(await loaded(notFound.children)) == "このアカウントからは見つからないユーザーです(押せない)")
        let failed = try #require(otherAccountsNode(accounts: [try account(resolveAccount: { _ in throw URLError(.notConnectedToInternet) })]))
        #expect(MenuNodeTests.describe(await loaded(failed.children)) == "ユーザーを探せませんでした(押せない)")
    }

    /// メニューを開くたびに、前に見つけた相手との関係を、そのアカウントで読み直す。「別のアカウントで」を組まない並びでは読まない。
    @Test func refreshReloadsRelationOfKnownPerson() async throws {
        let otherAlice = otherAlice
        let fetched = Mutex<[[String]]>([])
        let bob = try account(resolveAccount: { _ in otherAlice }, relationships: { ids in
            fetched.withLock { $0.append(ids) }
            return ids.map { Relationship(id: $0) }
        })
        _ = await bob.lookUpPerson(at: try #require(Self.aliceURL))
        let tree = UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: actions([bob]), linkBrowser: .inApp)

        tree.refreshOtherAccounts(groups: MenuLayout<UserMenuItem>.Groups(main: [.init([.follow])], more: []))
        tree.refreshOtherAccounts(groups: groups)
        try await waitUntil { fetched.withLock { $0 } == [["500"]] }
    }

    /// ナビゲーションバーから出すメニューでは、「別のアカウントで」の行そのものを、すべてのアカウントで相手を探し、関係も読み終えてから出す。
    /// 見つからなかったアカウントと探せなかったアカウントも、その結果を中に入れて出す。決まりはdocs/menus.mdの「メニューの単位」にある。
    @Test func barMenuLoadsOtherAccountsBeforeShowing() async throws {
        let otherAlice = otherAlice
        let bob = try account("bob", resolveAccount: { _ in otherAlice }, relationships: { ids in ids.map { Relationship(id: $0, following: true) } })
        let carol = try account("carol", resolveAccount: { _ in nil })
        let dave = try account("dave", resolveAccount: { _ in throw URLError(.notConnectedToInternet) })
        let node = try #require(otherAccountsNode(accounts: [bob, carol, dave]))
        let row = try #require(MenuNode.submenu("", [node]).loadingSubmenusBeforeShowing().children.first)
        guard case .deferred(let load) = row.content else {
            Issue.record("「別のアカウントで」の行を、読み終えてから出していません")
            return
        }
        let loaded = await load()
        #expect(MenuNodeTests.describe(loaded) == "別のアカウントで[@bob[メンション,リストに追加,フォローを外す,ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日]],@carol[このアカウントからは見つからないユーザーです(押せない)],@dave[ユーザーを探せませんでした(押せない)]]")
    }

    /// 投稿のメニューに何人も出るときは、前に見つけた人たちとの関係を、ほかのアカウントごとにまとめて1回で読み直す。
    @Test func refreshOfStatusMenuUsersBatchesRelationships() async throws {
        let people = (1...3).map { Account(id: "\($0)", username: "user\($0)", acct: "user\($0)@remote.example", displayName: "", avatar: nil, url: URL(string: "https://remote.example/@user\($0)")) }
        let fetched = Mutex<[[String]]>([])
        let bob = try account(resolveAccount: { url in
            people.first { $0.url == url }.map { Account(id: "5\($0.id)", username: $0.username, acct: $0.acct, displayName: "", avatar: nil, url: $0.url) }
        }, relationships: { ids in
            fetched.withLock { $0.append(ids) }
            return ids.map { Relationship(id: $0) }
        })
        for person in people {
            _ = await bob.lookUpPerson(at: try #require(person.url))
        }
        var tree = StatusMenuTree(
            status: Status(
                id: "100", createdAt: Date(timeIntervalSince1970: 100), account: people[0], content: "", spoilerText: "", uri: "https://remote.example/statuses/100", url: nil,
                mentions: people.dropFirst().map { Mention(id: $0.id, username: $0.username, url: $0.url, acct: $0.acct) }
            ),
            notification: nil, now: Date(timeIntervalSince1970: 0), linkBrowser: .inApp
        )
        tree.userMenu = MenuLayout<UserMenuItem>.Groups(main: [.init([.follow, .otherAccounts])], more: [])
        tree.userActions = actions([bob])

        tree.menu(groups: MenuLayout<StatusMenuItem>.Groups(main: [.init([.author, .mentionedUsers])], more: []), includesFollowRequest: false).refreshOtherAccountUsers()
        try await waitUntil { !fetched.withLock { $0 }.isEmpty }
        #expect(fetched.withLock { $0 } == [["51", "52", "53"]])
    }

    /// 投稿のメニューのユーザーのサブメニューにも出し、投稿のメニューの「別のアカウントで」の中のユーザーのメニューには出さない。
    @Test func appearsInStatusMenuUserSubmenuButNotInsideOtherAccount() async throws {
        let uri = "https://remote.example/users/alice/statuses/1"
        let otherAlice = otherAlice
        let found = Status(id: "7000", createdAt: Date(timeIntervalSince1970: 100), account: otherAlice, content: "", spoilerText: "", uri: uri, url: nil)
        let bobWithStatus = try account(search: { _ in [found] }, resolveAccount: { _ in otherAlice })
        var tree = StatusMenuTree(
            status: Status(id: "100", createdAt: Date(timeIntervalSince1970: 100), account: alice, content: "", spoilerText: "", uri: uri, url: nil),
            notification: nil, now: Date(timeIntervalSince1970: 0), linkBrowser: .inApp
        )
        tree.userMenu = MenuLayout<UserMenuItem>.Groups(main: [.init([.follow, .otherAccounts])], more: [])
        tree.userActions = actions([bobWithStatus])
        tree.otherAccounts = [bobWithStatus]
        tree.otherAccountGroups = .single(.author)

        let author = try #require(tree.menu(groups: .single(.author), includesFollowRequest: false).root?.flattenedChildren.first)
        #expect(author.flattenedChildren.contains { $0.title == "@bobで" })

        let otherAccount = try #require(tree.menu(groups: .single(.otherAccounts), includesFollowRequest: false).root?.flattenedChildren.first)
        guard case .deferred(let load) = otherAccount.children.first?.content else {
            Issue.record("開いてから投稿を探していません")
            return
        }
        let inner = await load()
        let innerAuthor = try #require(inner.flatMap(\.flattenedChildren).first { $0.title.hasPrefix("@alice") })
        #expect(!innerAuthor.flattenedChildren.contains { $0.title == "@bobで" || $0.title == "別のアカウントで" })
    }
}
