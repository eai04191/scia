import SciaCore
import UIKit

/// リンクのメニュー。本文のリンクの長押しと、リンクカードの長押しで、同じ並びから組む。決まりはdocs/menus.mdの「メニューの単位」にある。
/// 項目の名前、並び、出す条件、見出し、動きはここだけが知る。出す場所は、URLと、その場所でしかできないこと（共有のシートを出す起点、プロフィールを開く先）だけを渡す。
@MainActor
struct LinkMenu {
    let url: URL
    /// URLの項目の動き。
    let handlers: URLMenuHandlers
    /// 「プロフィールとして開く」を選んだ。リンク先をプロフィールとしてサーバーで探して開く。
    let openAsProfile: @MainActor () -> Void

    /// 見出しにURLを置く。出す項目がなければnil。
    func menu(groups: MenuLayout<LinkMenuItem>.Groups) -> UIMenu? {
        let children = groups.menuElements { item in
            if let action = item.urlAction {
                return [action.action(url: url, handlers: handlers)]
            }
            switch item {
            case .openAsProfile:
                return [openAsProfileAction(item)]
            // 共通の項目は、上で中身から組んだ。
            case .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .copyLink, .share:
                return []
            }
        }
        return children.isEmpty ? nil : UIMenu(title: url.absoluteString, children: children)
    }

    /// 「プロフィールとして開く」。サーバーはhttpとhttps以外をURLとして探さず、ふつうの文字列の検索になるため、そのリンクでは押せないようにする。
    private func openAsProfileAction(_ item: LinkMenuItem) -> UIAction {
        let isWeb = ["http", "https"].contains(url.scheme?.lowercased())
        return UIAction(title: item.title, image: item.image, attributes: isWeb ? [] : .disabled) { [openAsProfile] _ in openAsProfile() }
    }
}
