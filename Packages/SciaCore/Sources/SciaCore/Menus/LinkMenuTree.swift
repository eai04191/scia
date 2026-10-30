public import Foundation

/// リンクのメニューの項目を押したときの操作。
public enum LinkMenuCommand: Equatable, Sendable {
    case url(URLMenuCommand)
    /// リンク先をプロフィールとしてサーバーで探して開く。
    case openAsProfile
}

/// リンクのメニュー。本文のリンクの長押しと、リンクカードの長押しで、同じ並びから組む。決まりはdocs/menus.mdの「メニューの単位」にある。
/// 項目の名前、並び、出す条件、見出しはここだけが知る。押したときの動き（共有のシートを出す起点、プロフィールを開く先）は、出す場所が決める。
public struct LinkMenuTree {
    public let url: URL
    /// 開く場所の設定。メニューを組むときの値で決める。
    public let linkBrowser: LinkBrowser

    public init(url: URL, linkBrowser: LinkBrowser) {
        self.url = url
        self.linkBrowser = linkBrowser
    }

    /// 見出しにURLを置く。出す項目がなければnil。
    @MainActor
    public func menu(groups: MenuLayout<LinkMenuItem>.Groups) -> MenuNode<LinkMenuCommand>? {
        let children = groups.nodes { item -> [MenuNode<LinkMenuCommand>] in
            if let action = item.urlAction {
                return [action.node(url: url, linkBrowser: linkBrowser).map(LinkMenuCommand.url)]
            }
            switch item {
            case .openAsProfile:
                return [openAsProfileNode(item)]
            // 共通の項目は、上で中身から組んだ。
            case .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .copyLink, .share:
                return []
            }
        }
        return children.isEmpty ? nil : .submenu(url.absoluteString, children)
    }

    /// 「プロフィールとして開く」。サーバーはhttpとhttps以外をURLとして探さず、ふつうの文字列の検索になるため、そのリンクでは押せないようにする。
    private func openAsProfileNode(_ item: LinkMenuItem) -> MenuNode<LinkMenuCommand> {
        let isWeb = ["http", "https"].contains(url.scheme?.lowercased())
        return .action(item.title, icon: .symbol(item.symbolName), isEnabled: isWeb, .openAsProfile)
    }
}

/// ほかのサービスの投稿のメニューの項目を押したときの操作。
public enum ExternalPostMenuCommand: Equatable, Sendable {
    case url(URLMenuCommand)
    case copyText(String)
    case translate(String)
}

/// Xの投稿の囲みのような、ほかのサービスの投稿を長押ししたときに出すメニュー。
public struct ExternalPostMenuTree {
    /// 元の投稿のURL。
    public let url: URL
    /// コピーや翻訳に渡す本文。本文がなければnilで、本文を使う項目を出さない。
    public let text: String?
    public let linkBrowser: LinkBrowser

    public init(url: URL, text: String?, linkBrowser: LinkBrowser) {
        self.url = url
        self.text = text
        self.linkBrowser = linkBrowser
    }

    /// 見出しにURLを置く。出す項目がなければnil。
    @MainActor
    public func menu(groups: MenuLayout<ExternalPostMenuItem>.Groups) -> MenuNode<ExternalPostMenuCommand>? {
        let children = groups.nodes { item -> [MenuNode<ExternalPostMenuCommand>] in
            if let action = item.urlAction {
                return [action.node(url: url, linkBrowser: linkBrowser).map(ExternalPostMenuCommand.url)]
            }
            switch item {
            case .copyText:
                guard let text else { return [] }
                return [.action(item.title, icon: .symbol(item.symbolName), .copyText(text))]
            case .systemTranslate:
                guard let text else { return [] }
                return [.action(item.title, icon: .symbol(item.symbolName), .translate(text))]
            // 共通の項目は、上で中身から組んだ。
            case .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .copyLink, .share:
                return []
            }
        }
        return children.isEmpty ? nil : .submenu(url.absoluteString, children)
    }
}
