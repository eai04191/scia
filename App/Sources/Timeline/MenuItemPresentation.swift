import SciaCore
import UIKit

@MainActor
extension MenuLayout.Groups {
    /// まとまりごとに区切り線で分けて並べ、「その他」の中身はサブメニューにする。中身のないまとまりと「その他」は出さない。
    /// 横並びのまとまりは、アイコンと名前を縦に積んだ中くらいの大きさで横に並べる。横に並ぶのは3個までで、4個目からはその下にふだんの行として続く。
    func menuElements(_ elements: (Item) -> [UIMenuElement]) -> [UIMenuElement] {
        arranged(elements, group: { children, isRow in
            let menu = UIMenu(options: .displayInline, children: children)
            if isRow { menu.preferredElementSize = .medium }
            return menu
        }, more: { UIMenu(title: "その他", image: UIImage(systemName: "ellipsis.circle"), children: $0) })
    }
}

extension MenuItemContentProviding {
    var image: UIImage? { UIImage(systemName: symbolName) }
}

/// ハッシュタグのメニュー。本文のハッシュタグの長押しと、投稿のメニューの「ハッシュタグ」で、同じ並びから組む。決まりはdocs/menus.mdの「メニューの単位」にある。
/// 項目の名前、並び、出す条件、見出しはSciaCoreの`HashtagMenuTree`が決め、ここではUIKitのメニューに描いて、押した項目の動きを呼ぶ。
/// 出す場所は、タグと、その場所でしかできないこと（共有のシートを出す起点、一覧を開く先）だけを渡す。
@MainActor
struct HashtagMenu {
    /// `#`を除いた名前。
    let name: String
    /// サーバーのハッシュタグのページ。分からなければ、URLの項目を押せないまま並べる。
    let url: URL?
    /// 「投稿したユーザーの投稿」で開くユーザー。nilなら項目を出さない。
    let account: Account?
    /// URLの項目の動き。
    let handlers: URLMenuHandlers
    /// ミュートを読んで変えるもの。nilなら「ミュート」を出さない。
    let muteActions: HashtagMuteActions?
    /// 「すべての投稿」で、ハッシュタグのタイムラインを開く。
    let openTimeline: () -> Void
    /// 「投稿したユーザーの投稿」で、そのユーザーのハッシュタグの付いた投稿を開く。
    let openAccountStatuses: (Account) -> Void

    var tree: HashtagMenuTree {
        HashtagMenuTree(name: name, url: url, account: account, linkBrowser: handlers.linkBrowser, muteActions: muteActions)
    }

    /// 本文のハッシュタグの長押しで単独で出すメニュー。見出しに`#名前`を置く。出す項目がなければnil。
    func menu(groups: MenuLayout<HashtagMenuItem>.Groups) -> UIMenu? {
        built(groups: groups)?.menu
    }

    func built(groups: MenuLayout<HashtagMenuItem>.Groups) -> BuiltMenu<HashtagMenuCommand>? {
        tree.menu(groups: groups).map { BuiltMenu(root: $0, renderer: MenuRenderer(perform: perform)) }
    }

    func perform(_ command: HashtagMenuCommand) {
        switch command {
        case .url(let command): handlers.perform(command)
        case .openTimeline: openTimeline()
        case .openAccountStatuses(let account): openAccountStatuses(account)
        case .mute(let duration): muteActions?.mute(name, duration)
        case .unmute: muteActions?.unmute(name)
        }
    }
}

extension UIMenu {
    /// ユーザーのメニュー。投稿のメニューのサブメニューでも、ほかの場所から出すメニューでも、見出しを`UserHeading`で揃える。
    /// - Parameter image: サブメニューの項目に付ける、その人のアイコン。単独で出すメニューではnil。
    static func user(acct: String, image: UIImage? = nil, children: [UIMenuElement]) -> UIMenu {
        let heading = UserHeading(acct: acct)
        // 単独で出すメニューの見出しでは、UIKitがサブタイトルを描かないため、サーバー名を2行目に置く。
        if image == nil, let subtitle = heading.subtitle {
            return UIMenu(title: "\(heading.title)\n\(subtitle)", children: children)
        }
        return UIMenu(title: heading.title, subtitle: heading.subtitle, image: image, children: children)
    }
}

/// ユーザーのメニューの、メンション、ハンドルをコピー、関係の項目で使う相手。
enum UserMenuTarget {
    /// APIの`Account`や`mentions`から取ったIDと`acct`。そのまま使える。
    case account(id: String, acct: String)
    /// 本文や自己紹介のメンションのリンク。APIの`mentions`にないリンクでは、パーサーはリンクの文字列を`acct`の代わりにするが、
    /// Mastodonはほかのサーバーのユーザーでもリンクの文字列からサーバー名を省くため、そのままでは別のユーザーを指す。プロフィールのURLでアカウントを引いて`acct`を決める。
    /// - Parameter shownAcct: 見つからなかったときの知らせに出す、リンクの文字列から取った名前。
    case profileURL(URL, shownAcct: String)
}

/// ユーザーのメニューの、投稿欄とログイン中のサーバーに頼る項目（メンション、ハンドルをコピー、関係の項目）の動き。項目は`UserMenu`が組む。
/// セッションが作り、画面を組み立てる側が渡す。渡されていない画面では、これらの項目を出さない。
struct UserMenuActions {
    /// 投稿欄で、カーソルの位置に`@acct`を入れる。
    let mention: @MainActor (UserMenuTarget) -> Void
    /// サーバー名を付けた`@username@domain`の形でコピーし、コピーできたら`notify`を呼ぶ。
    let copyHandle: @MainActor (UserMenuTarget, _ notify: @escaping @MainActor () -> Void) -> Void
    /// 相手のIDと`acct`を決める。リンクのメンションは、プロフィールのURLから探す。見つからなければ投げる。
    let resolveTarget: @MainActor (UserMenuTarget) async throws -> UserIdentity
    /// `resolveTarget`で決めた相手と自分の関係を読む。覚えている関係を読み直している途中なら、それを待つ。自分ならnil。
    let loadRelation: @MainActor (UserMenuTarget, UserIdentity) async throws -> UserRelation?
    /// 手元で分かっている相手との関係。相手のIDが分からないか、関係を覚えていなければnil。
    let knownRelation: @MainActor (UserMenuTarget) -> KnownRelation?
    /// 相手たちとの関係をまとめて1回で読み直し、覚えておく。自分は除く。
    let reloadRelations: @MainActor ([String]) -> Void
    /// 関係の項目で選んだ変更を送る。取り消しにくい変更は、確かめてから送る。
    let changeRelation: @MainActor (UserRelationChange, UserRelation) -> Void
    /// 相手のプロフィールに書く、自分にしか見えないメモのシートを開く。
    let editNote: @MainActor (UserRelation) -> Void
    /// 通報のシートを開く。投稿のメニューから開いたときは、添えられる相手の投稿のIDを渡す。
    let report: @MainActor (_ accountID: String, _ acct: String, _ statusID: String?) -> Void
    /// セッションで読んだアカウント。メンションされたユーザーのように、アイコンのURLが手元にない相手のアイコンを出すのに使う。
    let accounts: AccountCache

}
