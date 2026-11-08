import SciaCore
import UIKit

/// ユーザーのメニュー。投稿のメニューのサブメニュー、アイコンや人のリストの行、本文や自己紹介のメンション、プロフィール画面の「…」で、同じ並びから組む。
/// 決まりはdocs/menus.mdの「ユーザーのメニュー」にある。項目の名前、並び、出す条件、見出しはSciaCoreの`UserMenuTree`が決め、ここではUIKitのメニューに描いて、押した項目の動きを呼ぶ。
/// 出す場所は、相手と、その場所でしかできないこと（共有のシートを出す起点、プロフィールを開く先、その人のアイコン）だけを渡す。
@MainActor
struct UserMenu {
    let subject: UserMenuSubject
    /// セッションの、メンション、ハンドルとその一部のコピー、関係の項目を組むもの。nilなら、これらの項目を出さない。
    let actions: UserMenuActions?
    /// URLの項目の動き。
    let handlers: URLMenuHandlers
    /// ハンドルやその一部をコピーしたことを知らせる画面。
    weak var host: (any LinkMenuHost)?
    /// 通報に添えられる投稿。Mastodonは通報する相手の投稿しか添えられないため、長押しした投稿を相手が書いたときだけ渡す。
    var reportableStatusID: String?
    /// 「別のアカウントで」の中の並び。設定のユーザーのメニューの、ほかのメニューの中に出すときの並びを渡す。
    /// タップや長押しに「別のアカウントで」だけを割り当てて組んでも、中身をユーザーのメニューの並びで組むため。
    var otherAccountGroups: MenuLayout<UserMenuItem>.Groups?

    init(subject: UserMenuSubject, actions: UserMenuActions?, handlers: URLMenuHandlers, host: (any LinkMenuHost)?, reportableStatusID: String? = nil) {
        self.subject = subject
        self.actions = actions
        self.handlers = handlers
        self.host = host
        self.reportableStatusID = reportableStatusID
    }

    var tree: UserMenuTree {
        var tree = UserMenuTree(subject: subject, actions: actions, linkBrowser: handlers.linkBrowser, reportableStatusID: reportableStatusID)
        tree.otherAccountGroups = otherAccountGroups
        return tree
    }

    /// 単独で出すメニュー（アイコンや人のリストの行、本文や自己紹介のメンション）。開くたびに、その人の関係を読み直す。出す項目がなければnil。
    /// - Parameters:
    ///   - avatar: 「プロフィール」に付けるその人のアイコン。
    ///   - avatarImage: アイコンの画像。nilを返したら記号を付ける。
    func built(groups: MenuLayout<UserMenuItem>.Groups, openProfile: @escaping @MainActor () -> Void, avatar: MenuAvatar, avatarImage: @escaping @MainActor (MenuAvatar) -> UIImage?) -> BuiltMenu<UserMenuCommand>? {
        let root = tree.menu(groups: groups, avatar: avatar)
        reloadRelation(groups: groups)
        return root.map { BuiltMenu(root: $0, renderer: renderer(openProfile: openProfile, avatarImage: avatarImage)) }
    }

    /// プロフィール画面のナビゲーションバーの「…」に出すメニュー。開くたびに、その人の関係を読み直す。出す項目がなければnil。
    /// - Parameters:
    ///   - avatarImage: 「別のアカウントで」のアカウントの行のアイコンの画像。nilを返したら記号を付ける。
    ///   - didRenderDeferred: 開いてから読む中身を描き終えたあとに呼ぶ。描きながら集めた、まだ読んでいないアイコンを読み始める。
    func profileScreenMenu(groups: MenuLayout<UserMenuItem>.Groups, avatarImage: @escaping @MainActor (MenuAvatar) -> UIImage?, didRenderDeferred: @escaping @MainActor () -> Void) -> UIMenu? {
        let root = tree.profileScreenMenu(groups: groups)
        reloadRelation(groups: groups)
        var renderer = renderer(openProfile: nil, avatarImage: avatarImage)
        renderer.didRenderDeferred = didRenderDeferred
        // ナビゲーションバーのボタンから出すので、中身を読む項目を含むサブメニューは、読み終えてから出す。
        return root.map { renderer.menu($0.loadingSubmenusBeforeShowing()) }
    }

    /// プロフィールのハンドルを押したときのメニュー。コピーの項目を決まった順に出す。出す項目がなければnil。
    func handleMenu() -> UIMenu? {
        tree.handleMenu().map { renderer(openProfile: nil) { _ in nil }.menu($0) }
    }

    /// 関係で中身が変わる項目を出していれば、その人の関係を読み直す。「別のアカウントで」を出していれば、ほかのアカウントでの関係も読み直す。
    /// 組んだメニューは覚えていた関係のまま出し、読み直した関係は次に開いたときから使う。
    private func reloadRelation(groups: MenuLayout<UserMenuItem>.Groups) {
        let tree = tree
        tree.refreshOtherAccounts(groups: groups)
        guard let id = tree.relationReloadID(groups: groups) else { return }
        actions?.reloadRelations([id])
    }

    /// - Parameters:
    ///   - openProfile: 「プロフィール」で開く。プロフィール画面ではnil。
    ///   - avatarImage: アイコンの画像。nilを返したら記号を付ける。
    func renderer(openProfile: (@MainActor () -> Void)?, avatarImage: @escaping @MainActor (MenuAvatar) -> UIImage?) -> MenuRenderer<UserMenuCommand> {
        MenuRenderer { command in
            perform(command, openProfile: openProfile)
        } customIcon: { icon in
            guard case .avatar(let avatar, _) = icon else { return nil }
            return avatarImage(avatar)
        }
    }

    func perform(_ command: UserMenuCommand, openProfile: (@MainActor () -> Void)?) {
        switch command {
        case .url(let command):
            handlers.perform(command)
        case .openProfile:
            openProfile?()
        case .mention:
            actions?.mention(subject.target)
        case .copy(let part):
            actions?.copy(subject.target, part) { [weak host] in host?.showHandleCopiedNotice(part) }
        case .changeRelation(let change, let relation):
            actions?.changeRelation(change, relation)
        case .editNote(let relation):
            actions?.editNote(relation)
        case .report(let accountID, let acct, let statusID):
            actions?.report(accountID, acct, statusID)
        case .addToList:
            actions?.addToList(subject.target)
        case .otherAccount(let account, let action):
            actions?.performAsOtherAccount(account, action)
        case .logIn(let account):
            actions?.logIn(account)
        case .customize:
            handlers.openSettings(.userMenu)
        }
    }
}
