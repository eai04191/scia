import SciaCore
import UIKit

@MainActor
extension MenuLayout.Groups {
    /// まとまりごとに区切り線で分けて並べ、「その他」の中身はサブメニューにする。中身のないまとまりと「その他」は出さない。
    /// 横並びのまとまりは、その大きさで横に並べる。横に並ぶ数（`MenuRowSize.capacity`）を超えた項目は、その下にふだんの行として続く。
    func menuElements(_ elements: (Item) -> [UIMenuElement]) -> [UIMenuElement] {
        arranged(elements, group: { UIMenu.group($0, row: $1) }, more: { UIMenu(title: TimelineScreenTexts.moreMenu, image: UIImage(systemName: "ellipsis.circle"), children: $0) })
    }
}

/// 横並びのまとまりの項目に、サブタイトルを出すか。
@MainActor
enum MenuRowSubtitles {
    /// VoiceOverでは見た目の幅や高さが関わらず、押せない理由などを読み上げで伝えるため、出したままにする。
    static var areShown: Bool { UIAccessibility.isVoiceOverRunning }
}

@MainActor
extension UIMenu {
    /// 区切り線で分けたまとまり。横並びなら、その大きさで横に並べ、横に並ぶ項目のサブタイトルを出さない。
    /// 狭い幅では長い文字が途中で切れ、出たときだけ段が高くなって下の項目を押し出すため。横に並ぶ数を超えてふだんの行で出る項目には残す。
    /// 開いてから中身を読む項目（`UIDeferredMenuElement`）は、UIKitが中身を見せないので、読んだ項目のサブタイトルは残る。木から描くメニュー（`MenuRenderer`）では、読んだ項目からも除く。
    static func group(_ children: [UIMenuElement], row: MenuRowSize?) -> UIMenu {
        let menu = UIMenu(options: .displayInline, children: children)
        guard let row else { return menu }
        menu.preferredElementSize = row.elementSize
        guard !MenuRowSubtitles.areShown else { return menu }
        for child in children.prefix(row.capacity) {
            (child as? UIAction)?.subtitle = nil
            (child as? UIMenu)?.subtitle = nil
        }
        return menu
    }
}

extension MenuRowSize {
    var elementSize: UIMenu.ElementSize {
        switch self {
        case .medium: .medium
        case .small: .small
        }
    }
}

extension MenuItemContentProviding {
    var image: UIImage? { UIImage(systemName: symbolName) }
}

/// ハッシュタグのメニュー。本文のハッシュタグの長押しと、投稿のメニューの「ハッシュタグ」で、同じ並びから組む。決まりはdocs/menus.mdの「メニューの単位」にある。
/// 項目の名前、並び、出す条件、見出しはSciaCoreの`HashtagMenuTree`が決め、ここではUIKitのメニューに描いて、押した項目の動きを呼ぶ。
/// 出す場所は、タグと、その場所でしかできないこと（共有のシートを出す起点、タイムラインを開く先）だけを渡す。
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
    /// ミュートなど、自分の状態を読んで変える項目のためのもの。nilなら、それらの項目を出さない。
    let actions: HashtagMenuActions?
    /// 「すべての投稿」で、ハッシュタグのタイムラインを開く。
    let openTimeline: () -> Void
    /// 「投稿したユーザーの投稿」で、そのユーザーのハッシュタグの付いた投稿を開く。
    let openAccountStatuses: (Account) -> Void

    var tree: HashtagMenuTree {
        HashtagMenuTree(name: name, url: url, account: account, linkBrowser: handlers.linkBrowser, actions: actions)
    }

    /// 本文のハッシュタグの長押しで単独で出すメニュー。見出しに`#名前`を置く。出す項目がなければnil。
    func built(groups: MenuLayout<HashtagMenuItem>.Groups) -> BuiltMenu<HashtagMenuCommand>? {
        tree.menu(groups: groups).map { BuiltMenu(root: $0, renderer: MenuRenderer(perform: perform)) }
    }

    func perform(_ command: HashtagMenuCommand) {
        switch command {
        case .url(let command): handlers.perform(command)
        case .openTimeline: openTimeline()
        case .openAccountStatuses(let account): openAccountStatuses(account)
        case .addToCompose: actions?.addToCompose?(name)
        case .mute(let duration): actions?.mute?.mute(name, duration)
        case .unmute: actions?.mute?.unmute(name)
        case .follow: actions?.follow?.turnOn(name)
        case .unfollow: actions?.follow?.turnOff(name)
        case .feature: actions?.feature?.turnOn(name)
        case .unfeature: actions?.feature?.turnOff(name)
        case .customize: handlers.openSettings(.hashtagMenu)
        }
    }
}
