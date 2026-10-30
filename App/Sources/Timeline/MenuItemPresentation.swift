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
