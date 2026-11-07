import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// 投稿のメニューの「別のアカウントで」を確かめる。決まりはdocs/other-accounts.mdにある。
@MainActor
struct OtherAccountMenuTests {
    private struct Failure: Error {}

    private let uri = "https://remote.example/users/alice/statuses/1"
    private let alice = Account(id: "1", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil, url: URL(string: "https://remote.example/@alice"))

    /// 今のアカウントのサーバーでの投稿。
    private func status(id: String = "100", uri: String?, account: Account? = nil, mentions: [Mention] = [], favourited: Bool = false, visibility: Status.Visibility = .public) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 100), account: account ?? alice, content: "<p>こんにちは</p>", spoilerText: "", uri: uri, url: nil, mentions: mentions, visibility: visibility, favourited: favourited)
    }

    private func mention(_ id: String, _ username: String) -> Mention {
        Mention(id: id, username: username, url: URL(string: "https://remote.example/@\(username)"), acct: "\(username)@remote.example")
    }

    /// `booster`が`status`をブーストした、今のアカウントのサーバーでの投稿。
    private func boost(of status: Status, by booster: Account) -> Status {
        Status(id: "200", createdAt: Date(timeIntervalSince1970: 100), account: booster, content: "", spoilerText: "", url: nil, reblog: status)
    }

    /// `title`で始まる名前のサブメニュー。
    private func submenu(_ title: String, in nodes: [MenuNode<StatusMenuCommand>]) -> MenuNode<StatusMenuCommand>? {
        nodes.flatMap { node -> [MenuNode<StatusMenuCommand>] in
            if case .group(let children, _) = node.content { return children }
            return [node]
        }.first { $0.title == title }
    }

    /// サブメニューのアイコンの人のID。人のアイコンでなければnil。
    private func avatarUserID(_ node: MenuNode<StatusMenuCommand>?) -> String? {
        guard case .avatar(.user(let user), _) = node?.icon else { return nil }
        return user.id
    }

    private func credential(_ username: String, server: String = "other.example", accountID: String = "50") throws -> Credential {
        Credential(instance: try #require(URL(string: "https://\(server)")), accessToken: "token", clientID: "id", clientSecret: "secret", accountID: accountID, username: username)
    }

    private func operations(
        search: @escaping @Sendable (String) async throws -> [Status],
        favourite: @escaping @Sendable (Status.ID) async throws -> Status = { _ in throw Failure() },
        profile: @escaping @Sendable () async throws -> Account = { throw Failure() },
        relationships: @escaping RelationshipCache.Fetch = { _ in throw Failure() },
        changeRelation: @escaping @Sendable (UserRelationChange, String) async throws -> Relationship = { _, _ in throw Failure() },
        resolveAccount: @escaping @Sendable (URL) async throws -> Account? = { _ in nil },
        deleteStatus: @escaping @Sendable (Status.ID) async throws -> Void = { _ in throw Failure() },
        capabilities: @escaping @Sendable () async throws -> ServerCapabilities = { throw Failure() },
        addEmojiReaction: @escaping @Sendable (Status.ID, ReactionEmoji) async throws -> Status = { _, _ in throw Failure() }
    ) -> OtherAccount.Operations {
        OtherAccount.Operations(search: search, interactions: StatusInteractions.Operations(
            favourite: favourite,
            unfavourite: { _ in throw Failure() },
            reblog: { _, _ in throw Failure() },
            unreblog: { _ in throw Failure() },
            bookmark: { _ in throw Failure() },
            unbookmark: { _ in throw Failure() },
            muteConversation: { _ in throw Failure() },
            unmuteConversation: { _ in throw Failure() },
            pin: { _ in throw Failure() },
            unpin: { _ in throw Failure() },
            addEmojiReaction: addEmojiReaction,
            removeEmojiReaction: { _, _ in throw Failure() }
        ), profile: profile, relationships: relationships, changeRelation: changeRelation, resolveAccount: resolveAccount, deleteStatus: deleteStatus, capabilities: capabilities)
    }

    private func account(_ username: String, server: String = "other.example", accountID: String = "50", _ operations: OtherAccount.Operations) throws -> OtherAccount {
        OtherAccount(credential: try credential(username, server: server, accountID: accountID), operations: operations, tasks: TaskScope())
    }

    private func tree(_ status: Status, accounts: [OtherAccount], groups: MenuLayout<StatusMenuItem>.Groups = StatusMenuItem.defaultLayout.groups) -> StatusMenuTree {
        var tree = StatusMenuTree(status: status, notification: nil, now: Date(timeIntervalSince1970: 0), linkBrowser: .inApp)
        tree.myAccountID = "9"
        tree.otherAccounts = accounts
        tree.otherAccountGroups = groups
        return tree
    }

    /// ブーストとお気に入りを横に並べ、ブックマークを続けた並び。そのアカウントから見た状態を確かめるテストで、項目を絞るのに使う。
    private let interactionGroups = MenuLayout<StatusMenuItem>.Groups(main: [.init([.reblog, .favourite], isRow: true), .init([.bookmark])], more: [])

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
        let groups = MenuLayout<StatusMenuItem>.Groups(main: interactionGroups.main + [.init([.author])], more: [])
        let menu = try #require(node(tree(status(uri: uri), accounts: [bob], groups: groups)))

        #expect(await loaded(menu.children).hasPrefix("=ブースト,お気に入りを取り消す|ブックマーク|@alice["))
        #expect(queries.withLock { $0 } == [uri])

        let reopened = try #require(node(tree(status(uri: uri), accounts: [bob], groups: groups)))
        #expect(MenuNodeTests.describe(reopened.children).hasPrefix("=ブースト,お気に入りを取り消す|ブックマーク|@alice["))
        let favourite = try #require(reopened.flattenedChildren.first { $0.title == "お気に入りを取り消す" })
        guard case .otherAccount(let command) = favourite.command else {
            Issue.record("ほかのアカウントの操作になっていません")
            return
        }
        #expect(command.account === bob)
        guard case .status(let target, .favourite) = command.action else {
            Issue.record("お気に入りの操作になっていません")
            return
        }
        #expect(target.id == "7000")
    }

    /// 中身は渡した並びに従い、「その他」もそのまま出す。どのアカウントでも同じ結果になる項目（カスタマイズ）と、そのアカウントが書いていない投稿の削除は出さない。
    @Test func followsGivenLayoutIncludingMore() async throws {
        let found = status(id: "7000", uri: uri)
        let bob = try account("bob", operations { _ in [found] })
        let groups = MenuLayout<StatusMenuItem>.Groups(
            main: [.init([.favourite, .reply, .reblogWithVisibility])],
            more: [.init([.bookmark, .delete, .customize])]
        )
        let menu = try #require(node(tree(status(uri: uri), accounts: [bob], groups: groups)))

        let items = await loaded(menu.children)
        #expect(items == "お気に入り,返信,公開範囲を選んでブースト[公開,ひかえめな公開,フォロワーのみ]|その他[ブックマーク]")
    }

    /// どのアカウントでも同じ結果になる項目（コピー、共有、今のアカウントで開く画面）は出さない。
    /// そのアカウントが書いた投稿なら、固定と削除をそのアカウントとして出す。
    @Test func excludesItemsSameForEveryAccount() async throws {
        let me = Account(id: "50", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)
        let found = status(id: "7000", uri: uri, account: me)
        let bob = try account("bob", operations { _ in [found] })
        let groups = MenuLayout<StatusMenuItem>.Groups(
            main: [.init([.openThread, .copyLink, .copyText, .share, .openInBrowser, .favouritedBy, .apiResponse, .customize]), .init([.pin, .delete])],
            more: []
        )

        let items = await loaded(try #require(node(tree(status(uri: uri, account: me), accounts: [bob], groups: groups))).children)
        #expect(items == "プロフィールに固定,削除!")
        let menu = try #require(node(tree(status(uri: uri, account: me), accounts: [bob], groups: groups)))
        let delete = try #require(menu.flattenedChildren.first { $0.title == "削除" })
        guard case .otherAccount(let command) = delete.command, case .status(let target, .delete) = command.action else {
            Issue.record("ほかのアカウントの削除になっていません")
            return
        }
        #expect(target.id == "7000")
    }

    /// ブーストした人は、見つけた投稿に入っていないので、そのサーバーでプロフィールのURLで探し、そのサーバーでのIDで出す。
    /// URLが違う人は使わない。見つけた人は覚え、次は探さない。見つからない人は出さず、次に開いたメニューでは待たない。
    @Test func resolvesBoosterOnOtherServer() async throws {
        let carl = Account(id: "3", username: "carl", acct: "carl@third.example", displayName: "Carl", avatar: nil, url: URL(string: "https://third.example/@carl"))
        let dan = Account(id: "4", username: "dan", acct: "dan@third.example", displayName: "Dan", avatar: nil, url: URL(string: "https://third.example/@dan"))
        let otherCarl = Account(id: "600", username: "carl", acct: "carl@third.example", displayName: "Carl", avatar: nil, url: carl.url)
        let found = status(id: "7000", uri: uri)
        let queries = Mutex<[URL]>([])
        let bob = try account("bob", operations(search: { _ in [found] }, resolveAccount: { url in
            queries.withLock { $0.append(url) }
            // URLの違う人が返ることもある。
            return url == carl.url ? otherCarl : Account(id: "601", username: "dan2", acct: "dan2@third.example", displayName: "Dan", avatar: nil, url: URL(string: "https://third.example/@dan2"))
        }))
        let groups = MenuLayout<StatusMenuItem>.Groups(main: [.init([.booster])], more: [])

        let built = await loaded(try #require(node(tree(boost(of: status(uri: uri), by: carl), accounts: [bob], groups: groups))).children)
        #expect(built.hasPrefix("@carl["))
        let reopened = tree(boost(of: status(uri: uri), by: carl), accounts: [bob], groups: groups)
        #expect(submenu("@carl", in: try #require(node(reopened)).children) != nil)
        #expect(reopened.menu(groups: .single(.otherAccounts), includesFollowRequest: false).otherAccountRelationIDs(found, bob) == ["600"])

        #expect(await loaded(try #require(node(tree(boost(of: status(uri: uri), by: dan), accounts: [bob], groups: groups))).children) == "")
        // 見つからなかった人を待たずに、覚えている投稿ですぐ組む。
        #expect(MenuNodeTests.describe(try #require(node(tree(boost(of: status(uri: uri), by: dan), accounts: [bob], groups: groups))).children) == "")
        #expect(queries.withLock { $0 } == [carl.url, dan.url].compactMap(\.self))
    }

    /// 投稿を覚えていても、まだ探していない人がブーストしたものなら、開いてから探してその人を出す。
    @Test func resolvesNewBoosterOfKnownStatus() async throws {
        let carl = Account(id: "3", username: "carl", acct: "carl@third.example", displayName: "Carl", avatar: nil, url: URL(string: "https://third.example/@carl"))
        let otherCarl = Account(id: "600", username: "carl", acct: "carl@third.example", displayName: "Carl", avatar: nil, url: carl.url)
        let found = status(id: "7000", uri: uri)
        let bob = try account("bob", operations(search: { _ in [found] }, resolveAccount: { $0 == carl.url ? otherCarl : nil }))
        let groups = MenuLayout<StatusMenuItem>.Groups(main: [.init([.favourite]), .init([.booster])], more: [])
        _ = await bob.lookup(status(uri: uri))

        let children = try #require(node(tree(boost(of: status(uri: uri), by: carl), accounts: [bob], groups: groups))).children
        #expect(MenuNodeTests.describe(children) == "…")
        #expect(await loaded(children).contains("|@carl["))
    }

    /// 並びでブーストした人を出さなければ、その人を探さない。
    @Test func doesNotResolveHiddenBooster() async throws {
        let carl = Account(id: "3", username: "carl", acct: "carl@third.example", displayName: "Carl", avatar: nil, url: URL(string: "https://third.example/@carl"))
        let found = status(id: "7000", uri: uri)
        let queries = Mutex(0)
        let bob = try account("bob", operations(search: { _ in [found] }, resolveAccount: { _ in
            queries.withLock { $0 += 1 }
            return nil
        }))

        _ = await loaded(try #require(node(tree(boost(of: status(uri: uri), by: carl), accounts: [bob], groups: interactionGroups))).children)
        #expect(queries.withLock { $0 } == 0)
    }

    /// メモ、通報、リストに追加は、そのアカウントのサーバーでの相手と投稿のIDで、そのアカウントのシートを開く命令にする。
    /// メンションは、そのアカウントのサーバーから見たハンドルで、投稿欄をそのアカウントに切り替えて入れる命令にする。
    @Test func opensSheetsAsOtherAccount() async throws {
        let otherAlice = Account(id: "500", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil, url: alice.url)
        let found = status(id: "7000", uri: uri, account: otherAlice)
        let bob = try account("bob", operations(search: { _ in [found] }, relationships: { ids in ids.map { Relationship(id: $0) } }))
        let groups = MenuLayout<StatusMenuItem>.Groups(main: [.init([.author])], more: [])
        _ = await bob.lookup(status(uri: uri))
        bob.reloadRelations(["500"])
        try await waitUntil { bob.userActions.knownRelation(.account(id: "500", acct: "alice@remote.example")) != nil }

        let menu = try #require(node(tree(status(uri: uri), accounts: [bob], groups: groups)))
        let aliceMenu = try #require(submenu("@alice", in: menu.children))
        func action(_ title: String) throws -> OtherAccountUserAction {
            let item = try #require(aliceMenu.flattenedChildren.first { $0.title.hasPrefix(title) })
            guard case .otherAccount(let command) = item.command, case .user(let action) = command.action else { throw Failure() }
            #expect(command.account === bob)
            return action
        }
        guard case .note(let relation) = try action("メモ") else {
            Issue.record("メモのシートの命令になっていません")
            return
        }
        #expect(relation.accountID == "500")
        guard case .report(let accountID, _, let statusID) = try action("通報") else {
            Issue.record("通報のシートの命令になっていません")
            return
        }
        #expect(accountID == "500")
        #expect(statusID == "7000")
        guard case .addToList(let listedID, let acct) = try action("リストに追加") else {
            Issue.record("リストに追加のシートの命令になっていません")
            return
        }
        #expect(listedID == "500")
        #expect(acct == "alice@remote.example")
        guard case .mention(let mentioned) = try action("メンション") else {
            Issue.record("投稿欄でメンションする命令になっていません")
            return
        }
        #expect(mentioned == "alice@remote.example")
    }

    /// ハッシュタグは、そのアカウントでのフォローなどの状態で項目を出し、そのアカウントとして行う命令にする。どのアカウントでも同じ結果になる項目は出さない。
    @Test func showsHashtagMenusAsOtherAccount() async throws {
        let found = Status(id: "7000", createdAt: Date(timeIntervalSince1970: 100), account: alice, content: "", spoilerText: "", uri: uri, url: nil, tags: [Tag(name: "swift", url: nil)])
        let bob = try account("bob", operations { _ in [found] })
        bob.hashtagActions = HashtagMenuActions(mute: nil, follow: HashtagToggleActions(
            known: { _ in true },
            refresh: {},
            load: { _ in true },
            turnOn: { _ in },
            turnOff: { _ in }
        ))
        let groups = MenuLayout<StatusMenuItem>.Groups(main: [.init([.hashtags])], more: [])
        _ = await bob.lookup(status(uri: uri))

        let menu = try #require(node(tree(status(uri: uri), accounts: [bob], groups: groups)))
        #expect(MenuNodeTests.describe(menu.children) == "#swift[フォローを外す]")
        let unfollow = try #require(menu.flattenedChildren.first?.flattenedChildren.first)
        guard case .otherAccount(let command) = unfollow.command, case .hashtag(let tag, .unfollow) = command.action else {
            Issue.record("ほかのアカウントのハッシュタグの命令になっていません")
            return
        }
        #expect(tag.name == "swift")
        #expect(command.account === bob)
    }

    /// 関係を読む人を集めるときは、ハッシュタグを組まず、ハッシュタグの読み直しを重ねて送らない。
    @Test func collectingRelationIDsDoesNotRefreshHashtags() async throws {
        let found = Status(id: "7000", createdAt: Date(timeIntervalSince1970: 100), account: alice, content: "", spoilerText: "", uri: uri, url: nil, tags: [Tag(name: "swift", url: nil)])
        let bob = try account("bob", operations { _ in [found] })
        let refreshes = Mutex(0)
        bob.hashtagActions = HashtagMenuActions(mute: nil, follow: HashtagToggleActions(
            known: { _ in false },
            refresh: { refreshes.withLock { $0 += 1 } },
            load: { _ in false },
            turnOn: { _ in },
            turnOff: { _ in }
        ))
        let groups = MenuLayout<StatusMenuItem>.Groups(main: [.init([.author, .hashtags])], more: [])
        _ = await bob.lookup(status(uri: uri))
        let built = tree(status(uri: uri), accounts: [bob], groups: groups).menu(groups: .single(.otherAccounts), includesFollowRequest: false)
        let before = refreshes.withLock { $0 }

        #expect(built.otherAccountRelationIDs(found, bob) == ["1"])
        #expect(refreshes.withLock { $0 } == before)
    }

    /// 削除したら、覚えている投稿からも除き、次に開いたときは探し直す。
    @Test func deleteForgetsStatus() async throws {
        let found = status(id: "7000", uri: uri)
        let deleted = Mutex<[String]>([])
        let bob = try account("bob", operations(search: { _ in [found] }, deleteStatus: { id in deleted.withLock { $0.append(id) } }))
        let shown = status(uri: uri)
        _ = await bob.lookup(shown)

        try await bob.delete(found)

        #expect(deleted.withLock { $0 } == ["7000"])
        #expect(bob.known(shown) == nil)
    }

    /// 編集して返った投稿を覚え、編集の前に始めた検索の結果で戻さない。次の編集を、編集の前の添付で始めないため。
    @Test func editReplacesKnownStatus() async throws {
        let before = status(id: "7000", uri: uri)
        let refreshing = Gate()
        let searches = Mutex(0)
        let bob = try account("bob", operations(search: { _ in
            let count = searches.withLock { count in
                count += 1
                return count
            }
            if count > 1 { try await refreshing.wait() }
            return [before]
        }))
        let shown = status(uri: uri)
        _ = await bob.lookup(shown)

        let refresh = Task { await bob.lookup(shown) }
        try await waitUntil { refreshing.waiterCount == 1 }
        let edited = Status(id: "7000", createdAt: before.createdAt, account: before.account, content: "<p>編集した</p>", spoilerText: "", uri: uri, url: nil)
        bob.didEdit(edited)
        refreshing.open()
        _ = await refresh.value

        #expect(bob.known(shown)?.content == "<p>編集した</p>")
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

    /// そのアカウントがログアウトされていて探せなければ、理由の行に続けて、そのアカウントでログインし直す項目を出す。
    @Test func offersLogInWhenOtherAccountIsLoggedOut() async throws {
        let sender = RequestAccount(id: "https://other.example#50", handle: "@bob@other.example")
        let bob = try account("bob", operations { _ in throw MastodonAPIError(statusCode: 401, message: "The access token is invalid", account: sender) })

        let children = await loadedNodes(try #require(node(tree(status(uri: uri), accounts: [bob]))).children)

        #expect(MenuNodeTests.describe(children) == "投稿を探せませんでした(押せない)|ログインし直す")
        guard case .logIn(let account) = children.last?.command else {
            Issue.record("ログインし直す項目になっていません")
            return
        }
        #expect(account == sender)
    }

    /// 開いてから読む中身を読んで並べる。
    private func loadedNodes(_ nodes: [MenuNode<StatusMenuCommand>]) async -> [MenuNode<StatusMenuCommand>] {
        var loaded: [MenuNode<StatusMenuCommand>] = []
        for node in nodes {
            if case .deferred(let load) = node.content {
                loaded += await load()
            } else {
                loaded.append(node)
            }
        }
        return loaded
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
    /// リアクションは、そのアカウントのサーバーが絵文字のリアクションに対応していると読めたときだけ出す。読めないうちと、読めなかったときは出さない。
    @Test func showsEmojiReactionOnlyWhenOtherServerSupportsIt() async throws {
        let found = status(id: "7000", uri: uri)
        let groups = MenuLayout<StatusMenuItem>.Groups(main: [.init([.favourite, .emojiReaction])], more: [])
        let gate = Gate()
        let fedibird = try account("bob", operations(search: { _ in [found] }, capabilities: {
            try await gate.wait()
            return ServerCapabilities(fedibirdCapabilities: ["emoji_reaction"])
        }))
        let mastodon = try account("carol", operations(search: { _ in [found] }, capabilities: { .mastodon }))
        let failing = try account("dave", operations(search: { _ in [found] }))

        #expect(await loaded(try #require(node(tree(status(uri: uri), accounts: [fedibird], groups: groups))).children) == "お気に入り")
        fedibird.loadCapabilities()
        mastodon.loadCapabilities()
        failing.loadCapabilities()
        gate.open()
        try await waitUntil { fedibird.supportsEmojiReactions }

        #expect(MenuNodeTests.describe(try #require(node(tree(status(uri: uri), accounts: [fedibird], groups: groups))).children) == "お気に入り,リアクション")
        #expect(await loaded(try #require(node(tree(status(uri: uri), accounts: [mastodon], groups: groups))).children) == "お気に入り")
        #expect(await loaded(try #require(node(tree(status(uri: uri), accounts: [failing], groups: groups))).children) == "お気に入り")
    }

    /// 読めなかったサーバーの対応は、次に呼ばれたときに読み直す。読めたら読み直さない。
    @Test func reloadsCapabilitiesOnlyAfterFailure() async throws {
        let calls = Mutex(0)
        let bob = try account("bob", operations(search: { _ in [] }, capabilities: {
            let call = calls.withLock { $0 += 1; return $0 }
            guard call > 1 else { throw Failure() }
            return ServerCapabilities(fedibirdCapabilities: ["emoji_reaction"])
        }))

        bob.loadCapabilities()
        try await waitUntil { calls.withLock { $0 } == 1 && !bob.isLoadingCapabilities }
        #expect(!bob.supportsEmojiReactions)
        bob.loadCapabilities()
        try await waitUntil { bob.supportsEmojiReactions }
        bob.loadCapabilities()
        #expect(calls.withLock { $0 } == 2)
    }

    /// リアクションは、そのアカウントとして、そのサーバーでの投稿のIDに付け、覚えている投稿にも入れる。すでに付けている絵文字なら、付けたままにする。
    @Test func reactsAsOtherAccount() async throws {
        let found = status(id: "7000", uri: uri)
        let emoji = ReactionEmoji(name: "🤔")
        let reactedStatus = Status(id: "7000", createdAt: Date(timeIntervalSince1970: 100), account: alice, content: "<p>こんにちは</p>", spoilerText: "", uri: uri, url: nil, emojiReactions: [EmojiReaction(emoji: emoji, count: 1, me: true)])
        let reacted = Mutex<[Status.ID]>([])
        let bob = try account("bob", operations(search: { _ in [found] }, addEmojiReaction: { id, _ in
            reacted.withLock { $0.append(id) }
            return reactedStatus
        }))
        let shown = status(uri: uri)
        guard case .found(let resolved) = await bob.lookup(shown) else {
            Issue.record("投稿が見つかりません")
            return
        }

        #expect(try await bob.react(with: emoji, on: resolved))
        #expect(reacted.withLock { $0 } == ["7000"])
        #expect(bob.known(shown)?.hasEmojiReaction(emoji) == true)
    }

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
        let menu = try #require(node(tree(status(uri: uri, visibility: .private), accounts: [author], groups: interactionGroups)))

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

    /// 投稿者とメンションされた人のユーザーのメニューを、そのアカウントから見た関係で出す。相手は、そのサーバーでのIDで扱う。
    /// 出る人の関係は、見つけたときにまとめて1回で読む。どのアカウントでも同じ結果になる項目は出さない。
    /// アイコンは、今のアカウントで同じ人をプロフィールのURLで探して付け、見つからない人には付けない。
    @Test func showsUserMenusAsOtherAccount() async throws {
        let carol = mention("2", "carol")
        let shown = status(uri: uri, mentions: [carol])
        let otherAlice = Account(id: "500", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil, url: alice.url)
        let found = status(id: "7000", uri: uri, account: otherAlice, mentions: [mention("501", "carol"), mention("502", "dave")])
        let fetched = Mutex<[[String]]>([])
        let bob = try account("bob", operations(search: { _ in [found] }, relationships: { ids in
            fetched.withLock { $0.append(ids) }
            return ids.map { Relationship(id: $0, following: $0 == "500") }
        }))

        let groups = MenuLayout<StatusMenuItem>.Groups(main: [.init([.favourite]), .init([.author, .mentionedUsers])], more: [])
        _ = await loaded(try #require(node(tree(shown, accounts: [bob], groups: groups))).children)
        try await waitUntil { bob.userActions.knownRelation(.account(id: "502", acct: "dave@remote.example")) != nil }
        #expect(fetched.withLock { $0 } == [["500", "501", "502"]])

        let items = try #require(node(tree(shown, accounts: [bob], groups: groups))).children
        let aliceMenu = try #require(submenu("@alice", in: items))
        #expect(MenuNodeTests.describe(aliceMenu.children).hasPrefix("メンション|フォローを外す,"))
        // どのアカウントでも同じ結果になるコピーやプロフィールは出さない。
        #expect(!MenuNodeTests.describe(aliceMenu.children).contains("コピー"))
        #expect(!MenuNodeTests.describe(aliceMenu.children).contains("プロフィール,"))
        #expect(avatarUserID(aliceMenu) == "1")
        #expect(avatarUserID(submenu("@carol", in: items)) == "2")
        let dave = try #require(submenu("@dave", in: items))
        #expect(dave.icon == nil)
        #expect(MenuNodeTests.describe(dave.children).hasPrefix("メンション|フォロー,"))

        let unfollow = try #require(aliceMenu.flattenedChildren.first { $0.title == "フォローを外す" })
        guard case .otherAccount(let command) = unfollow.command, case .user(.relation(.unfollow, let relation)) = command.action else {
            Issue.record("ほかのアカウントの関係の変更になっていません")
            return
        }
        #expect(relation.accountID == "500")
        #expect(command.account === bob)
    }

    /// 関係の変更は、そのアカウントとしてそのサーバーでのIDの相手へ送り、結果を次に開いたメニューで使う。
    @Test func changeUpdatesKnownRelation() async throws {
        let sent = Mutex<[String]>([])
        let bob = try account("bob", operations(search: { _ in [] }, changeRelation: { change, id in
            sent.withLock { $0.append("\(change)/\(id)") }
            return Relationship(id: id, following: true)
        }))
        let relation = UserRelation(accountID: "500", acct: "alice@remote.example", relationship: Relationship(id: "500"))

        let changed = try await bob.change(.follow, of: relation)

        #expect(changed.following)
        #expect(sent.withLock { $0 } == ["follow/500"])
        guard case .relation(let known) = bob.userActions.knownRelation(.account(id: "500", acct: "alice@remote.example")) else {
            Issue.record("関係を覚えていません")
            return
        }
        #expect(known.relationship.following)
    }

    /// そのアカウント自身が投稿者なら、自分に出せる項目（メモ、リストに追加）だけを出し、関係の項目は出さない。
    @Test func showsOwnUserMenuWithoutRelationItems() async throws {
        let me = Account(id: "50", username: "bob", acct: "bob", displayName: "Bob", avatar: nil)
        let found = status(id: "7000", uri: uri, account: me)
        let bob = try account("bob", operations(search: { _ in [found] }, relationships: { ids in ids.map { Relationship(id: $0) } }))
        let groups = MenuLayout<StatusMenuItem>.Groups(main: [.init([.author])], more: [])
        _ = await bob.lookup(status(uri: uri))
        bob.reloadRelations(["50"])
        try await waitUntil { bob.userActions.knownRelation(.account(id: "50", acct: "bob")).map { if case .myself(let relation) = $0 { relation != nil } else { false } } == true }

        let menu = try #require(node(tree(status(uri: uri), accounts: [bob], groups: groups)))
        let own = try #require(submenu("@bob", in: menu.children))
        let described = MenuNodeTests.describe(own.children)
        #expect(described.contains("リストに追加"))
        #expect(described.contains("メモ"))
        #expect(!described.contains("フォロー"))
        #expect(!described.contains("ブロック"))
    }

    /// アカウントの行のアイコンは、プロフィールを読む前からそのアカウント自身を指す。描く側が読み終えるのを待って差し替える。
    @Test func rowIconPointsToOtherAccountBeforeProfileIsLoaded() throws {
        let bob = try account("bob", operations(search: { _ in [] }))

        guard case .avatar(.otherAccount(let shown), _) = try #require(node(tree(status(uri: uri), accounts: [bob]))).icon else {
            Issue.record("アカウントの行のアイコンが、そのアカウントを指していません")
            return
        }
        #expect(shown === bob)
    }

    /// プロフィールを待つ呼び出しは、読んでいる途中の読み込みを待ち、送り直さない。読めなければnilを返し、次に呼ばれたときに読み直す。
    @Test func loadedProfileWaitsForRunningLoadAndRetriesAfterFailure() async throws {
        let me = Account(id: "50", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://other.example/bob.png"))
        let gate = Gate()
        let calls = Mutex(0)
        let bob = try account("bob", operations(search: { _ in [] }, profile: {
            let call = calls.withLock { $0 += 1; return $0 }
            guard call > 1 else { throw Failure() }
            try await gate.wait()
            return me
        }))

        #expect(await bob.loadedProfile() == nil)
        bob.loadProfile()
        async let waited = bob.loadedProfile()
        try await waitUntil { calls.withLock { $0 } == 2 }
        gate.open()
        #expect(await waited?.id == "50")
        #expect(calls.withLock { $0 } == 2)
        #expect(bob.profile?.id == "50")
    }

    /// 関係は、組んだメニューに出る人の分だけ読む。人の項目を並びから外していれば読まない。
    @Test func reloadsRelationsOnlyOfShownUsers() async throws {
        let otherAlice = Account(id: "500", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil, url: alice.url)
        let found = status(id: "7000", uri: uri, account: otherAlice, mentions: [mention("501", "carol")])
        let fetched = Mutex<[[String]]>([])
        let bob = try account("bob", operations(search: { _ in [found] }, relationships: { ids in
            fetched.withLock { $0.append(ids) }
            return ids.map { Relationship(id: $0) }
        }))
        let noUsers = MenuLayout<StatusMenuItem>.Groups(main: [.init([.favourite])], more: [])
        let authorOnly = MenuLayout<StatusMenuItem>.Groups(main: [.init([.favourite, .author])], more: [])

        _ = await loaded(try #require(node(tree(status(uri: uri), accounts: [bob], groups: noUsers))).children)
        let built = tree(status(uri: uri), accounts: [bob], groups: authorOnly).menu(groups: .single(.otherAccounts), includesFollowRequest: false)
        await bob.refresh(status(uri: uri), people: [], relationIDs: built.otherAccountRelationIDs)
        try await waitUntil { !fetched.withLock { $0 }.isEmpty }

        #expect(fetched.withLock { $0 } == [["500"]])
    }
}
