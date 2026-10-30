import SciaCore
import UIKit

/// リンクのメニュー。本文のリンクの長押しと、リンクカードの長押しで、同じ並びから組む。決まりはdocs/menus.mdの「メニューの単位」にある。
/// 項目の名前、並び、出す条件、見出しはSciaCoreの`LinkMenuTree`が決め、ここではUIKitのメニューに描いて、押した項目の動きを呼ぶ。
/// 出す場所は、URLと、その場所でしかできないこと（共有のシートを出す起点、プロフィールを開く先）だけを渡す。
@MainActor
struct LinkMenu {
    let url: URL
    /// URLの項目の動き。
    let handlers: URLMenuHandlers
    /// 「プロフィールとして開く」を選んだ。リンク先をプロフィールとしてサーバーで探して開く。
    let openAsProfile: @MainActor () -> Void

    /// 見出しにURLを置く。出す項目がなければnil。
    func menu(groups: MenuLayout<LinkMenuItem>.Groups) -> UIMenu? {
        built(groups: groups)?.menu
    }

    func built(groups: MenuLayout<LinkMenuItem>.Groups) -> BuiltMenu<LinkMenuCommand>? {
        LinkMenuTree(url: url, linkBrowser: handlers.linkBrowser).menu(groups: groups).map { root in
            BuiltMenu(root: root, renderer: MenuRenderer(perform: perform))
        }
    }

    private func perform(_ command: LinkMenuCommand) {
        switch command {
        case .url(let command): handlers.perform(command)
        case .openAsProfile: openAsProfile()
        }
    }
}
