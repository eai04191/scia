import SciaCore
import UIKit

/// ユーザーのメニュー。投稿のメニューのサブメニュー、アイコンや人の一覧の行、本文や自己紹介のメンション、プロフィール画面の「…」で、同じ並びから組む。
/// 決まりはdocs/menus.mdの「ユーザーのメニュー」にある。項目の名前、並び、出す条件、見出しはSciaCoreの`UserMenuTree`が決め、ここではUIKitのメニューに描いて、押した項目の動きを呼ぶ。
/// 出す場所は、相手と、その場所でしかできないこと（共有のシートを出す起点、プロフィールを開く先、その人のアイコン）だけを渡す。
@MainActor
struct UserMenu {
    let subject: UserMenuSubject
    /// セッションの、メンション、ハンドルをコピー、関係の項目を組むもの。nilなら、これらの項目を出さない。
    let actions: UserMenuActions?
    /// URLの項目の動き。
    let handlers: URLMenuHandlers
    /// ハンドルをコピーしたことを知らせる画面。
    weak var host: (any LinkMenuHost)?
    /// 通報に添えられる投稿。Mastodonは通報する相手の投稿しか添えられないため、長押しした投稿を相手が書いたときだけ渡す。
    var reportableStatusID: String?

    init(subject: UserMenuSubject, actions: UserMenuActions?, handlers: URLMenuHandlers, host: (any LinkMenuHost)?, reportableStatusID: String? = nil) {
        self.subject = subject
        self.actions = actions
        self.handlers = handlers
        self.host = host
        self.reportableStatusID = reportableStatusID
    }

    var tree: UserMenuTree {
        UserMenuTree(subject: subject, actions: actions, linkBrowser: handlers.linkBrowser, reportableStatusID: reportableStatusID)
    }

    /// 単独で出すメニュー（アイコンや人の一覧の行、本文や自己紹介のメンション）。開くたびに、その人の関係を読み直す。出す項目がなければnil。
    /// - Parameters:
    ///   - avatar: 「プロフィール」に付けるその人のアイコン。
    ///   - avatarImage: アイコンの画像。nilを返したら記号を付ける。
    func built(groups: MenuLayout<UserMenuItem>.Groups, openProfile: @escaping @MainActor () -> Void, avatar: MenuAvatar, avatarImage: @escaping @MainActor (MenuAvatar) -> UIImage?) -> BuiltMenu<UserMenuCommand>? {
        let root = tree.menu(groups: groups, avatar: avatar)
        reloadRelation(groups: groups)
        return root.map { BuiltMenu(root: $0, renderer: renderer(openProfile: openProfile, avatarImage: avatarImage)) }
    }

    func menu(groups: MenuLayout<UserMenuItem>.Groups, openProfile: @escaping @MainActor () -> Void, avatar: MenuAvatar, avatarImage: @escaping @MainActor (MenuAvatar) -> UIImage?) -> UIMenu? {
        built(groups: groups, openProfile: openProfile, avatar: avatar, avatarImage: avatarImage)?.menu
    }

    /// プロフィール画面のナビゲーションバーの「…」に出すメニュー。開くたびに、その人の関係を読み直す。出す項目がなければnil。
    func profileScreenMenu(groups: MenuLayout<UserMenuItem>.Groups) -> UIMenu? {
        let root = tree.profileScreenMenu(groups: groups)
        reloadRelation(groups: groups)
        return root.map { renderer(openProfile: nil) { _ in nil }.menu($0) }
    }

    /// 関係で中身が変わる項目を出していれば、その人の関係を読み直す。組んだメニューは覚えていた関係のまま出し、読み直した関係は次に開いたときから使う。
    private func reloadRelation(groups: MenuLayout<UserMenuItem>.Groups) {
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
        case .copyHandle:
            actions?.copyHandle(subject.target) { [weak host] in host?.showHandleCopiedNotice() }
        case .changeRelation(let change, let relation):
            actions?.changeRelation(change, relation)
        case .editNote(let relation):
            actions?.editNote(relation)
        case .report(let accountID, let acct, let statusID):
            actions?.report(accountID, acct, statusID)
        }
    }
}
