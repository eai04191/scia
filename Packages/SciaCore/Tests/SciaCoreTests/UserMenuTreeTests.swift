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
            mention: { _ in }, copyHandle: { _, _ in },
            resolveTarget: { _ in throw CancellationError() }, loadRelation: { _, _ in nil }, knownRelation: known, reloadRelations: { _ in },
            changeRelation: { _, _ in }, editNote: { _ in }, report: { _, _, _ in }, accounts: AccountCache { _ in [] }
        )
    }

    private func layout(visible: Set<UserMenuItem>) -> MenuLayout<UserMenuItem>.Groups {
        MenuLayout(elements: UserMenuItem.allCases.map { .item($0, isVisible: visible.contains($0)) } + [.more]).groups
    }

    private func submenu(_ groups: MenuLayout<UserMenuItem>.Groups = UserMenuItem.defaultLayout.groups, actions: UserMenuActions? = nil) -> String? {
        UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: actions, linkBrowser: .inApp)
            .submenu(groups: groups, avatar: .user(.account(alice)))
            .map { MenuNodeTests.describe([$0]) }
    }

    // MARK: - 関係の項目

    /// フォローは、していなければフォロー、していれば外す、リクエスト中なら取り消す。ブロックしているか、されていれば出さない。
    @Test func followItemFollowsRelationship() {
        #expect(describe(.follow, Relationship(id: "2")) == "フォロー")
        #expect(describe(.follow, Relationship(id: "2", following: true)) == "フォローを外す")
        #expect(describe(.follow, Relationship(id: "2", requested: true)) == "フォローのリクエストを取り消す")
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

        // 既定の並びでは、メモがフォローより先に出る。
        #expect(UserMenuItem.defaultLayout.groups.relationFailureSlots(waitsForReport: false) == RelationFailureSlots(relation: .note, resolve: .note))
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

    /// 既定のユーザーのメニューは、開く・書く操作（メモを含む）、フォロー、持ち出す操作でまとまりを分け、フォローの設定、ミュート、ブロックは「その他」に入れる。
    /// 関係を覚えていない相手の関係の項目は、読んでから中身を決める。通報は関係で変わらないため、読まずに出す。開く場所を選んで開く2つは隠れている。
    @Test func defaultUserMenuHasMentionAndCopyUsername() {
        #expect(submenu(actions: actions()) == "@alice[プロフィール,メンション,…,…,ハンドルをコピー,リンクをコピー,共有,ブラウザで開く,その他[…,…,…,…,通報]]")
    }

    /// メンション、ハンドルをコピー、関係の項目を組むものを渡されていない画面では、これらを出さない。
    @Test func omitsMentionAndCopyUsernameWithoutActions() {
        #expect(submenu() == "@alice[プロフィール,リンクをコピー,共有,ブラウザで開く]")
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

        #expect(user.hasPrefix("@alice[プロフィール,メンション,メモを追加,フォローを外す,"))
        #expect(!user.contains("…"))
    }

    /// 自分には関係の項目も通報も出さない。
    @Test func myselfHasNoRelationItems() {
        #expect(submenu(actions: actions { _ in .myself }) == "@alice[プロフィール,メンション,ハンドルをコピー,リンクをコピー,共有,ブラウザで開く]")
    }

    /// 「その他」に何かあれば、1項目でもサブメニューにする。出す項目がなければ何も出さない。
    @Test func submenuWhenProfileIsInMoreAndNothingWhenEmpty() {
        #expect(submenu(MenuLayout(elements: [.more, .item(.profile, isVisible: true)]).groups) == "@alice[その他[プロフィール,リンクをコピー,共有,ブラウザで開く]]")
        #expect(submenu(layout(visible: [])) == nil)
    }

    // MARK: - 単独で出すメニュー

    /// 単独で出すメニューは、見出しの2行目にサーバー名を置く。プロフィール画面のメニューは見出しを置かず、「プロフィール」を出さない。
    /// 関係を読み直すのは、関係で中身が変わる項目を出しているときだけ。
    @Test func standaloneAndProfileScreenMenus() throws {
        let tree = UserMenuTree(subject: UserMenuSubject(.account(alice)), actions: nil, linkBrowser: .inApp)
        let standalone = try #require(tree.menu(groups: UserMenuItem.defaultLayout.groups, avatar: .user(.account(alice))))
        let profile = try #require(tree.profileScreenMenu(groups: UserMenuItem.defaultLayout.groups))

        #expect(standalone.title == "@alice\nremote.example")
        #expect(standalone.flattenedChildren.first?.title == "プロフィール")
        #expect(profile.title.isEmpty)
        #expect(!profile.flattenedChildren.map(\.title).contains("プロフィール"))
        #expect(tree.relationReloadID(groups: UserMenuItem.defaultLayout.groups) == "2")
        #expect(tree.relationReloadID(groups: layout(visible: [.profile, .report])) == nil)
        let link = UserMenuTree(subject: UserMenuSubject(mentionLink: try #require(alice.url), acct: "alice"), actions: nil, linkBrowser: .inApp)
        #expect(link.relationReloadID(groups: UserMenuItem.defaultLayout.groups) == nil)
    }
}
