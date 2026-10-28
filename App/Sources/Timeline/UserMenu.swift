import SciaCore
import UIKit

/// ユーザーのメニューを出す相手。
struct UserMenuSubject {
    /// 見出しと、サブメニューにせず直接並べるときの名前に出す`acct`。
    let acct: String
    /// URLの項目で扱う、プロフィールのページのURL。
    let url: URL?
    /// メンション、ハンドルをコピー、関係の項目で使う相手。
    let target: UserMenuTarget

    init(_ user: MenuUser) {
        acct = user.acct
        url = user.url
        target = .account(id: user.id, acct: user.acct)
    }

    /// 本文や自己紹介のメンションのリンク。相手は、プロフィールのURLで探す。
    init(mentionLink url: URL, acct: String) {
        self.acct = acct
        self.url = url
        target = .profileURL(url, shownAcct: acct)
    }

    /// 相手のID。リンクのメンションでは、探すまで分からないのでnil。
    var id: String? {
        if case .account(let id, _) = target { id } else { nil }
    }
}

/// ユーザーのメニュー。投稿のメニューのサブメニュー、アイコンや人の一覧の行、本文や自己紹介のメンション、プロフィール画面の「…」で、同じ並びから組む。
/// 決まりはdocs/menus.mdの「ユーザーのメニュー」にある。項目の名前、並び、出す条件、見出し、動きはここだけが知る。
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

    /// 投稿のメニューに置く、`@acct`のサブメニュー。サブメニューの項目にその人のアイコンを付け、中の「プロフィール」は記号のままにする。同じ顔が2つ並ばないようにするため。
    /// 中身が1つで「その他」が空なら、サブメニューにせず「@acctのプロフィール」のように直接並べる。出す項目がなければnil。
    /// 関係の読み直しは、投稿のメニューに出る人をまとめて1回で頼むため、ここでは頼まない。
    /// - Parameter avatar: その人のアイコン。
    func submenu(groups: MenuLayout<UserMenuItem>.Groups, openProfile: @escaping @MainActor () -> Void, avatar: @escaping () -> UIImage) -> UIMenuElement? {
        // 関係の項目は読んでから中身が決まり、名前に相手を入れられないため、1つだけでもサブメニューにする。
        if groups.more.isEmpty, groups.main.count == 1, let only = groups.main.first?.items, only.count == 1, !only[0].isRelation {
            // サブメニューの項目に付けるアイコンがないので、「プロフィール」にその人のアイコンを付ける。
            return Items(menu: self, groups: groups, inSubmenu: false, openProfile: openProfile, profileIcon: avatar).elements(for: only[0]).first
        }
        let children = elements(groups: groups, inSubmenu: true, openProfile: openProfile) { nil }
        guard !children.isEmpty else { return nil }
        return UIMenu.user(acct: subject.acct, image: avatar(), children: children)
    }

    /// 単独で出すメニュー（アイコンや人の一覧の行、本文や自己紹介のメンション）。サブメニューの項目がないので、「プロフィール」にその人のアイコンを付ける。
    /// 開くたびに、その人の関係を読み直す。出す項目がなければnil。
    /// - Parameter avatar: その人のアイコン。nilなら記号を付ける。
    func menu(groups: MenuLayout<UserMenuItem>.Groups, openProfile: @escaping @MainActor () -> Void, avatar: @escaping () -> UIImage?) -> UIMenu? {
        let children = elements(groups: groups, inSubmenu: true, openProfile: openProfile, profileIcon: avatar)
        reloadRelation(groups: groups)
        return children.isEmpty ? nil : UIMenu.user(acct: subject.acct, children: children)
    }

    /// プロフィール画面のナビゲーションバーの「…」に出すメニュー。開いているプロフィールを開くだけの「プロフィール」は出さない。
    /// 見出しは置かない。開いているプロフィールの人のメニューなので、見れば分かるため。開くたびに、その人の関係を読み直す。出す項目がなければnil。
    func profileScreenMenu(groups: MenuLayout<UserMenuItem>.Groups) -> UIMenu? {
        let children = elements(groups: groups, inSubmenu: true, openProfile: nil) { nil }
        reloadRelation(groups: groups)
        return children.isEmpty ? nil : UIMenu(children: children)
    }

    /// 関係で中身が変わる項目を出していれば、その人の関係を読み直す。組んだメニューは覚えていた関係のまま出し、読み直した関係は次に開いたときから使う。
    /// リンクのメンションは、相手を探すまでIDが分からないため読み直さない。
    private func reloadRelation(groups: MenuLayout<UserMenuItem>.Groups) {
        guard let id = subject.id, groups.needsRelationship else { return }
        actions?.reloadRelations([id])
    }

    private func elements(groups: MenuLayout<UserMenuItem>.Groups, inSubmenu: Bool, openProfile: (@MainActor () -> Void)?, profileIcon: @escaping () -> UIImage?) -> [UIMenuElement] {
        let items = Items(menu: self, groups: groups, inSubmenu: inSubmenu, openProfile: openProfile, profileIcon: profileIcon)
        return groups.menuElements { items.elements(for: $0) }
    }

    /// メニューを1回組む間の、項目ごとの組み方。
    @MainActor
    private struct Items {
        let menu: UserMenu
        /// 見出しのあるメニューに並べる。falseなら、投稿のメニューに直接並べるため、名前に相手を入れる。
        let inSubmenu: Bool
        /// 「プロフィール」で開く。nilなら「プロフィール」を出さない。
        let openProfile: (@MainActor () -> Void)?
        /// 「プロフィール」に付けるアイコン。nilを返したら記号を付ける。
        let profileIcon: () -> UIImage?
        /// メニューを1回開く間、関係の項目で分け合う、相手の探し方と関係の読み方。
        let load: UserRelationLoad?
        let failureSlots: RelationFailureSlots

        init(menu: UserMenu, groups: MenuLayout<UserMenuItem>.Groups, inSubmenu: Bool, openProfile: (@MainActor () -> Void)?, profileIcon: @escaping () -> UIImage?) {
            self.menu = menu
            self.inSubmenu = inSubmenu
            self.openProfile = openProfile
            self.profileIcon = profileIcon
            load = menu.actions.map { UserMenu.relationLoad(for: menu.subject.target, actions: $0) }
            // 知らせる項目は、組む並びから決める。1項目だけ組むときに、出さない項目で知らせて空のメニューにならないため。
            // リンクのメンションは相手を探す必要があるので、通報も探すのを待って出す。
            failureSlots = groups.relationFailureSlots(waitsForReport: menu.subject.id == nil)
        }

        func elements(for item: UserMenuItem) -> [UIMenuElement] {
            let subject = menu.subject
            if let action = item.urlAction {
                return [action.action(title: inSubmenu ? nil : UserMenu.inlineTitle(of: action, acct: subject.acct), url: subject.url, handlers: menu.handlers)]
            }
            switch item {
            case .profile:
                guard let openProfile else { return [] }
                return [UIAction(title: inSubmenu ? item.title : "@\(subject.acct)のプロフィール", image: profileIcon() ?? item.image) { _ in openProfile() }]
            case .mention:
                guard let actions = menu.actions else { return [] }
                let target = subject.target
                return [UIAction(title: inSubmenu ? item.title : "@\(subject.acct)にメンション", image: item.image) { _ in actions.mention(target) }]
            case .copyHandle:
                guard let actions = menu.actions else { return [] }
                let target = subject.target
                return [UIAction(title: inSubmenu ? item.title : "@\(subject.acct)のハンドルをコピー", image: item.image) { [weak host = menu.host] _ in
                    actions.copyHandle(target) { host?.showHandleCopiedNotice() }
                }]
            case .follow, .showReblogs, .notify, .note, .mute, .block, .report:
                guard let actions = menu.actions, let load else { return [] }
                return menu.relationElements(item, actions: actions, load: load, failureSlots: failureSlots)
            // 共通の項目は、上で中身から組んだ。
            case .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
                return []
            }
        }
    }

    /// サブメニューにせず投稿のメニューに直接並べるときの、ユーザーの共通の項目の名前。
    fileprivate static func inlineTitle(of action: URLMenuAction, acct: String) -> String {
        switch action {
        case .copyLink: "@\(acct)のリンクをコピー"
        case .share: "@\(acct)を共有"
        case .openInBrowser: "@\(acct)をブラウザで開く"
        case .openInDefaultBrowser: "@\(acct)を既定のブラウザで開く"
        case .openInAppSafari: "@\(acct)をアプリ内のSafariで開く"
        }
    }
}
