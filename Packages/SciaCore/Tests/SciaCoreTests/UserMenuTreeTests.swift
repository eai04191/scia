import Foundation
import SciaCore
import Testing

/// ユーザーのメニューの組み方と、関係の項目が関係に合わせて中身を変えることを確かめる。決まりはdocs/menus.mdの「ユーザーのメニュー」にある。
@MainActor
struct UserMenuTreeTests {
    private let alice = Account(id: "2", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil, url: URL(string: "https://remote.example/@alice"))

    private func describe(_ item: UserMenuItem, _ relationship: Relationship) -> String {
        MenuNodeTests.describe(UserMenuTree.relationNodes(item, relation: UserRelation(accountID: "2", acct: "alice", relationship: relationship)))
    }

    /// - Parameter known: 手元で分かっている相手との関係。渡さなければ、どの相手の関係も覚えていない。
    private func actions(known: @escaping @MainActor (UserMenuTarget) -> KnownRelation? = { _ in nil }) -> UserMenuActions {
        UserMenuActions(
            mention: { _ in }, copy: { _, _, _ in }, localServer: "example.social",
            resolveTarget: { _ in throw CancellationError() }, loadRelation: { _, _ in nil }, knownRelation: known, reloadRelations: { _ in },
            changeRelation: { _, _ in }, editNote: { _ in }, report: { _, _, _ in }, addToList: { _ in }, accounts: AccountCache { _ in [] }
        )
    }

    private func layout(visible: Set<UserMenuItem>) -> MenuLayout<UserMenuItem>.Groups {
        MenuLayout(elements: UserMenuItem.allCases.map { .item($0, isVisible: visible.contains($0)) } + [.more]).groups
    }

    private func submenu(_ groups: MenuLayout<UserMenuItem>.Groups = MenuFixture.user.groups, actions: UserMenuActions? = nil) -> String? {
        UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: actions, linkBrowser: .inApp)
            .submenu(groups: groups, avatar: .user(.account(alice)))
            .map { MenuNodeTests.describe([$0]) }
    }

    // MARK: - 関係の項目

    /// フォローは、していなければフォロー、していれば外す、リクエスト中なら取り消す。ブロックしているか、されていれば出さない。
    @Test func followItemFollowsRelationship() {
        #expect(describe(.follow, Relationship(id: "2")) == "フォロー")
        #expect(describe(.follow, Relationship(id: "2", following: true)) == "フォローを外す")
        #expect(describe(.follow, Relationship(id: "2", requested: true)) == "フォローリクエストを取り消す")
        #expect(describe(.follow, Relationship(id: "2", blocking: true)).isEmpty)
        #expect(describe(.follow, Relationship(id: "2", blockedBy: true)).isEmpty)
    }

    /// フォローの設定は、フォロー中かリクエスト中の相手にだけ、今の設定をチェックで示して出す。
    @Test func followSettingsShowCurrentStateOnlyWhenFollowing() {
        #expect(describe(.showReblogs, Relationship(id: "2")).isEmpty)
        #expect(describe(.notify, Relationship(id: "2")).isEmpty)
        #expect(describe(.showReblogs, Relationship(id: "2", following: true, showingReblogs: true)) == "ブーストを表示✓")
        #expect(describe(.showReblogs, Relationship(id: "2", following: true, showingReblogs: false)) == "ブーストを表示")
        #expect(describe(.notify, Relationship(id: "2", notifying: true, requested: true)) == "投稿を通知✓")
    }

    /// プロフィールで紹介は、サーバーがフォローしていない相手を断るので、フォロー中の相手にだけ出し、紹介していれば外す。リクエスト中とブロックでは出さない。
    @Test func endorseItemShownOnlyWhenFollowing() throws {
        #expect(describe(.endorse, Relationship(id: "2")).isEmpty)
        #expect(describe(.endorse, Relationship(id: "2", requested: true)).isEmpty)
        #expect(describe(.endorse, Relationship(id: "2", following: true, blockedBy: true)).isEmpty)
        #expect(describe(.endorse, Relationship(id: "2", following: true)) == "プロフィールで紹介する")
        #expect(describe(.endorse, Relationship(id: "2", following: true, endorsed: true)) == "プロフィールから外す")

        let command = try #require(UserMenuTree.relationNodes(.endorse, relation: UserRelation(accountID: "2", acct: "alice", relationship: Relationship(id: "2", following: true, endorsed: true))).first?.command)
        guard case .changeRelation(.endorse(let endorses), _) = command else {
            Issue.record("紹介を変える操作になっていません")
            return
        }
        #expect(!endorses)
    }

    /// ミュートは期間を選ぶサブメニューにし、ミュート中なら解除を出す。ブロックは取り消せない操作として示し、ブロック中なら解除を出す。
    @Test func muteAndBlockItems() {
        #expect(describe(.mute, Relationship(id: "2")) == "ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日]")
        #expect(describe(.mute, Relationship(id: "2", muting: true)) == "ミュートを解除")
        #expect(describe(.block, Relationship(id: "2")) == "ブロック!")
        #expect(describe(.block, Relationship(id: "2", blocking: true)) == "ブロックを解除")
    }

    /// メモは、なければ「メモを追加」、あれば「メモを編集」にする。ブロックしていても書ける。押すとシートを開く。
    @Test func noteItemAddsOrEditsNote() throws {
        #expect(describe(.note, Relationship(id: "2")) == "メモを追加")
        #expect(describe(.note, Relationship(id: "2", note: "前に会った")) == "メモを編集")
        #expect(describe(.note, Relationship(id: "2", blocking: true)) == "メモを追加")

        let command = try #require(UserMenuTree.relationNodes(.note, relation: UserRelation(accountID: "2", acct: "alice", relationship: Relationship(id: "2"))).first?.command)
        guard case .editNote(let relation) = command else {
            Issue.record("メモのシートを開く操作になっていません")
            return
        }
        #expect(relation.accountID == "2")
    }

    /// 通報は関係によらず出し、添えられる投稿を渡す。
    @Test func reportItemIsAlwaysShown() throws {
        #expect(describe(.report, Relationship(id: "2")) == "通報")
        #expect(describe(.report, Relationship(id: "2", blocking: true)) == "通報")
        let command = try #require(UserMenuTree.relationNodes(.report, relation: UserRelation(accountID: "2", acct: "alice", relationship: Relationship(id: "2")), reportableStatusID: "100").first?.command)
        guard case .report(let accountID, let acct, let statusID) = command else {
            Issue.record("通報の操作になっていません")
            return
        }
        #expect([accountID, acct, statusID] == ["2", "alice", "100"])
    }

    /// 相手を探すのは、関係を読むのとは別に待てる。通報は探すのだけを待つので、関係を読めなくても出せる。
    /// 同じメニューの項目で分け合い、相手を探すのも関係を読むのも1度だけにする。
    @Test func identityIsSharedAndDoesNotWaitForRelation() async throws {
        let counts = LoadCounter()
        let load = UserRelationLoad {
            counts.resolves += 1
            return UserIdentity(id: "2", acct: "alice@remote.example")
        } load: { _ in
            counts.loads += 1
            throw URLError(.notConnectedToInternet)
        }

        #expect(try await load.identity.id == "2")
        #expect(counts.loads == 0)
        await #expect(throws: URLError.self) { try await load.value }
        await #expect(throws: URLError.self) { try await load.value }
        #expect(try await load.identity.acct == "alice@remote.example")
        #expect(counts.resolves == 1)
        #expect(counts.loads == 1)
    }

    @MainActor
    private final class LoadCounter {
        var resolves = 0
        var loads = 0
    }

    /// 関係を読めなかった知らせは、最初に出る、関係で中身が変わる項目の場所に出す。
    /// 相手を探せなかった知らせは、最初に出る、相手を探すのを待つ項目の場所に出す。通報は相手のIDが分かっていれば待たないので、探すときだけその場所になる。
    /// 通報を関係の項目より前に並べても、関係を読めなかった知らせは関係の項目の場所に出る。
    @Test func failureIsShownAtFirstItemThatWaitsForIt() {
        let reportOnly = layout(visible: [.profile, .report])
        let reportFirst = MenuLayout<UserMenuItem>(elements: [.item(.report, isVisible: true)] + UserMenuItem.allCases.filter { $0 != .report }.map { .item($0, isVisible: true) } + [.more]).groups

        // この並びでは、関係の項目のうちフォローが最初に出る。
        #expect(MenuFixture.user.groups.relationFailureSlots(waitsForReport: false) == RelationFailureSlots(relation: .follow, resolve: .follow))
        #expect(reportOnly.relationFailureSlots(waitsForReport: false) == RelationFailureSlots(relation: nil, resolve: nil))
        #expect(reportOnly.relationFailureSlots(waitsForReport: true) == RelationFailureSlots(relation: nil, resolve: .report))
        #expect(reportFirst.relationFailureSlots(waitsForReport: true) == RelationFailureSlots(relation: .follow, resolve: .report))
    }

    /// 相手を探せなかったら、知らせる項目の場所にだけ押せない行で知らせる。
    @Test func resolveFailureIsShownOnce() async throws {
        let tree = UserMenuTree(subject: UserMenuSubject(mentionLink: try #require(alice.url), acct: "alice"), actions: actions(), linkBrowser: .inApp)
        let menu = try #require(tree.menu(groups: layout(visible: [.note, .follow]), avatar: nil))
        var loaded: [String] = []
        for node in menu.flattenedChildren {
            guard case .deferred(let load) = node.content else { continue }
            loaded.append(MenuNodeTests.describe(await load()))
        }

        #expect(loaded == ["関係を読み込めませんでした(押せない)", ""])
    }

    // MARK: - 投稿のメニューのサブメニュー

    /// 既定のユーザーのメニューは、開く・書く操作、フォローとリストに追加、持ち出す操作、ミュート・ブロック・通報でまとまりを分け、ユーザー名とサーバーのコピー、メモ、フォローの設定、プロフィールで紹介は「その他」に入れる。
    /// 関係を覚えていない相手の関係の項目は、読んでから中身を決める。通報は関係で変わらないため、読まずに出す。開く場所を選んで開く2つは隠れている。
    @Test func defaultUserMenuHasMentionAndCopyUsername() {
        #expect(submenu(actions: actions()) == "@alice[プロフィール,メンション,…,リストに追加,ハンドルをコピー,リンクをコピー,共有,ブラウザで開く,…,…,通報,その他[ユーザー名をコピー,サーバーをコピー,…,…,…,…,カスタマイズ]]")
    }

    /// メンション、ハンドルをコピー、関係の項目を組むものを渡されていない画面では、これらを出さない。
    @Test func omitsMentionAndCopyUsernameWithoutActions() {
        #expect(submenu() == "@alice[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]]")
    }

    /// ユーザーのメニューの中身が1つで「その他」が空なら、サブメニューにせず、名前に相手を入れて直接並べる。プロフィールにはその人のアイコンを付ける。
    @Test func singleItemIsListedDirectly() {
        #expect(submenu(layout(visible: [.profile])) == "@alice@remote.exampleのプロフィール")
        #expect(submenu(layout(visible: [.mention]), actions: actions()) == "@alice@remote.exampleにメンション")
        let tree = UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: nil, linkBrowser: .inApp)
        guard case .avatar(.user(let user), let fallback) = tree.submenu(groups: layout(visible: [.profile]), avatar: .user(.account(alice)))?.icon else {
            Issue.record("その人のアイコンが付いていません")
            return
        }
        #expect(user.id == "2")
        #expect(fallback == "person.crop.circle")
    }

    /// カスタマイズは数えない。ほかの中身が1つなら、カスタマイズを出さずに直接並べる。1回余計に押す手間を省くため。
    @Test func customizeDoesNotPreventListingDirectly() {
        #expect(submenu(layout(visible: [.profile, .customize])) == "@alice@remote.exampleのプロフィール")
    }

    /// 関係の項目は、1つだけでもサブメニューにする。読んでから中身が決まり、名前に相手を入れられないため。
    @Test func singleRelationItemStaysInSubmenu() {
        #expect(submenu(layout(visible: [.follow]), actions: actions()) == "@alice[…]")
    }

    /// 関係を覚えている相手は、その関係で関係の項目をその場で組み、読み込み中の行を出さない。
    @Test func knownRelationBuildsRelationItemsImmediately() throws {
        let known = actions { target in
            guard case .account(let id, let acct) = target else { return nil }
            return .relation(UserRelation(accountID: id, acct: acct, relationship: Relationship(id: id, following: true)))
        }
        let user = try #require(submenu(actions: known))

        #expect(user.hasPrefix("@alice[プロフィール,メンション,フォローを外す,"))
        #expect(!user.contains("…"))
    }

    /// 自分には、関係の項目のうちメモだけを出し、通報も出さない。自分との関係を覚えていれば、メモの項目をその場で組む。
    @Test func myselfHasOnlyNoteItem() {
        let me = UserRelation(accountID: "2", acct: "alice", relationship: Relationship(id: "2", note: "TODO"))
        #expect(submenu(actions: actions { _ in .myself(me) }) == "@alice[プロフィール,メンション,リストに追加,ハンドルをコピー,リンクをコピー,共有,ブラウザで開く,その他[ユーザー名をコピー,サーバーをコピー,メモを編集,カスタマイズ]]")
        #expect(submenu(actions: actions { _ in .myself(nil) }) == "@alice[プロフィール,メンション,リストに追加,ハンドルをコピー,リンクをコピー,共有,ブラウザで開く,その他[ユーザー名をコピー,サーバーをコピー,…,カスタマイズ]]")
    }

    /// 自分との関係を覚えていなければ、読んでからメモの項目を組む。読めなければ、メモの場所に知らせる。自分にはほかに関係の項目を出さないため。
    @Test func myselfNoteWaitsForRelation() async throws {
        func loaded(_ loadRelation: @escaping @MainActor (UserMenuTarget, UserIdentity) async throws -> UserRelation?) async throws -> [String] {
            let actions = UserMenuActions(
                mention: { _ in }, copy: { _, _, _ in }, localServer: "example.social",
                resolveTarget: { _ in UserIdentity(id: "2", acct: "alice") }, loadRelation: loadRelation, knownRelation: { _ in .myself(nil) }, reloadRelations: { _ in },
                changeRelation: { _, _ in }, editNote: { _ in }, report: { _, _, _ in }, addToList: { _ in }, accounts: AccountCache { _ in [] }
            )
            let tree = UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: actions, linkBrowser: .inApp)
            let menu = try #require(tree.menu(groups: layout(visible: [.follow, .note, .mute]), avatar: nil))
            var loaded: [String] = []
            for node in menu.flattenedChildren {
                guard case .deferred(let load) = node.content else { continue }
                loaded.append(MenuNodeTests.describe(await load()))
            }
            return loaded
        }

        #expect(try await loaded { _, identity in UserRelation(accountID: identity.id, acct: identity.acct, relationship: Relationship(id: identity.id)) } == ["メモを追加"])
        #expect(try await loaded { _, _ in throw URLError(.notConnectedToInternet) } == ["関係を読み込めませんでした(押せない)"])
    }

    /// リンクのメンションから選んだ相手が自分だったら、探して関係を読んだあとも、メモのほかの関係の項目は出さない。
    @Test func mentionLinkToMyselfShowsOnlyNote() async throws {
        let actions = UserMenuActions(
            mention: { _ in }, copy: { _, _, _ in }, localServer: "example.social",
            resolveTarget: { _ in UserIdentity(id: "2", acct: "alice") },
            loadRelation: { _, identity in UserRelation(accountID: identity.id, acct: identity.acct, relationship: Relationship(id: identity.id)) },
            knownRelation: { target in
                guard case .account = target else { return nil }
                return .myself(nil)
            },
            reloadRelations: { _ in }, changeRelation: { _, _ in }, editNote: { _ in }, report: { _, _, _ in }, addToList: { _ in }, accounts: AccountCache { _ in [] }
        )
        let tree = UserMenuTree(subject: UserMenuSubject(mentionLink: try #require(alice.url), acct: "alice"), actions: actions, linkBrowser: .inApp)
        let menu = try #require(tree.menu(groups: layout(visible: [.follow, .note, .report]), avatar: nil))
        var loaded: [String] = []
        for node in menu.flattenedChildren {
            guard case .deferred(let load) = node.content else { continue }
            loaded.append(MenuNodeTests.describe(await load()))
        }

        #expect(loaded == ["", "メモを追加", ""])
    }

    /// 文字のままのハンドルは、プロフィールのURLが探すまで分からない。URLの項目は押せるまま並べ、押してから探す。ほかのサーバーで探すURLがないので「別のアカウントで」は出さない。
    @Test func plainHandleFindsURLAfterChoosing() throws {
        let tree = UserMenuTree(subject: UserMenuSubject(handle: "alice@example.social"), actions: actions(), linkBrowser: .inApp)
        let menu = try #require(tree.menu(groups: layout(visible: [.profile, .copyLink, .openInBrowser, .copyHandle, .otherAccounts]), avatar: nil))

        #expect(menu.flattenedChildren.map { MenuNodeTests.describe([$0]) } == ["プロフィール", "ハンドルをコピー", "リンクをコピー", "ブラウザで開く"])
        let commands = menu.flattenedChildren.compactMap { node -> URLMenuAction? in
            if case .action(.urlAfterFinding(let action)?) = node.content { action } else { nil }
        }
        #expect(commands == [.copyLink, .openInBrowser])
    }

    /// 検索の結果は、書かれたハンドルと同じ人だけを受け取る。同じサーバーの人の`acct`にはサーバー名がないので補って比べる。
    @Test func handleMatchIgnoresCaseAndAddsLocalServer() {
        func account(_ acct: String) -> Account { Account(id: "1", username: "alice", acct: acct, displayName: "", avatar: nil) }
        #expect(account("Alice@Example.Social").hasHandle("alice@example.social", localServer: "local.example"))
        #expect(account("alice").hasHandle("alice@local.example", localServer: "local.example"))
        #expect(!account("alice@other.example").hasHandle("alice@example.social", localServer: "local.example"))
        #expect(!account("alice").hasHandle("alice@example.social", localServer: "local.example"))
    }

    /// 「その他」に何かあれば、1項目でもサブメニューにする。出す項目がなければ何も出さない。
    @Test func submenuWhenProfileIsInMoreAndNothingWhenEmpty() {
        #expect(submenu(MenuLayout(elements: [.more, .item(.profile, isVisible: true)] + UserMenuItem.allCases.filter { $0 != .profile }.map { .item($0, isVisible: false) }).groups) == "@alice[その他[プロフィール]]")
        #expect(submenu(layout(visible: [])) == nil)
    }

    // MARK: - コピーの項目

    /// コピーの項目には、選んだらコピーされる文字をサブテキストに出す。同じサーバーの人には、ログインしているサーバーの名前を補う。
    @Test func copyItemsShowCopiedText() throws {
        let bob = Account(id: "3", username: "bob", acct: "bob", displayName: "Bob", avatar: nil, url: URL(string: "https://example.social/@bob"))
        func copies(_ account: Account) throws -> [String] {
            let tree = UserMenuTree(subject: UserMenuSubject(.account(account)), actions: actions(), linkBrowser: .inApp)
            let menu = try #require(tree.profileScreenMenu(groups: layout(visible: Set(UserMenuItem.copyItems))))
            return menu.flattenedChildren.map { "\($0.title)(\($0.subtitle ?? ""))" }
        }

        #expect(try copies(alice) == [
            "ハンドルをコピー(@alice@remote.example)", "ユーザー名をコピー(alice)", "サーバーをコピー(remote.example)", "リンクをコピー(https://remote.example/@alice)",
        ])
        #expect(try copies(bob) == [
            "ハンドルをコピー(@bob@example.social)", "ユーザー名をコピー(bob)", "サーバーをコピー(example.social)", "リンクをコピー(https://example.social/@bob)",
        ])
    }

    /// メンションのリンクから開いたメニューは、選ぶまで相手を探さないので、ハンドルとその一部のサブテキストを出さない。リンクはURLが分かるので出す。
    @Test func mentionLinkCopyItemsOmitHandleSubtitles() throws {
        let tree = UserMenuTree(subject: UserMenuSubject(mentionLink: try #require(alice.url), acct: "alice"), actions: actions(), linkBrowser: .inApp)
        let menu = try #require(tree.profileScreenMenu(groups: layout(visible: Set(UserMenuItem.copyItems))))
        #expect(menu.flattenedChildren.map(\.subtitle) == [nil, nil, nil, "https://remote.example/@alice"])
    }

    /// 投稿のメニューに直接並べるときは、名前に相手を入れる。
    @Test func inlineCopyItemsNameTheUser() throws {
        for item in UserMenuItem.copyItems {
            let tree = UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: actions(), linkBrowser: .inApp)
            let node = try #require(tree.submenu(groups: layout(visible: [item]), avatar: .user(.account(alice))))
            #expect(node.title == "@alice@remote.exampleの\(item.title)")
        }
    }

    /// プロフィールのハンドルのメニューは、並びの設定によらず、コピーの4つを決まった順に出す。見出しは置かない。
    @Test func handleMenuListsCopyItemsInOrder() throws {
        let tree = UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: actions(), linkBrowser: .inApp)
        let menu = try #require(tree.handleMenu())
        #expect(menu.title.isEmpty)
        #expect(menu.flattenedChildren.map(\.title) == ["ハンドルをコピー", "ユーザー名をコピー", "サーバーをコピー", "リンクをコピー"])
        let commands = menu.flattenedChildren.compactMap(\.command).map { command -> String in
            switch command {
            case .copy(let part): "\(part)"
            case .url(.copy(let url)): url.absoluteString
            default: "ほかの操作"
            }
        }
        #expect(commands == ["handle", "username", "server", "https://remote.example/@alice"])
    }

    // MARK: - 単独で出すメニュー

    /// 単独で出すメニューは、見出しの2行目にサーバー名を置く。プロフィール画面のメニューは見出しを置かず、「プロフィール」を出さない。
    /// 関係を読み直すのは、関係で中身が変わる項目を出しているときだけ。
    @Test func standaloneAndProfileScreenMenus() throws {
        let tree = UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: nil, linkBrowser: .inApp)
        let standalone = try #require(tree.menu(groups: MenuFixture.user.groups, avatar: .user(.account(alice))))
        let profile = try #require(tree.profileScreenMenu(groups: MenuFixture.user.groups))

        #expect(standalone.title == "@alice\nremote.example")
        #expect(standalone.flattenedChildren.first?.title == "プロフィール")
        #expect(profile.title.isEmpty)
        #expect(!profile.flattenedChildren.map(\.title).contains("プロフィール"))
        #expect(tree.relationReloadID(groups: MenuFixture.user.groups) == "2")
        #expect(tree.relationReloadID(groups: layout(visible: [.profile, .report])) == nil)
        let link = UserMenuTree(subject: UserMenuSubject(mentionLink: try #require(alice.url), acct: "alice"), actions: nil, linkBrowser: .inApp)
        #expect(link.relationReloadID(groups: MenuFixture.user.groups) == nil)
    }
}
