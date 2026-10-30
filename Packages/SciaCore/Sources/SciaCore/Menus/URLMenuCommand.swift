public import Foundation

/// ページのURLに対する共通の項目（`URLMenuAction`）を押したときの操作。コピーしたことの知らせ方、共有のシートの起点、開き方は、メニューを出す場所で決める。
public enum URLMenuCommand: Equatable, Sendable {
    case copy(URL)
    case share(URL)
    /// 開く項目と開く場所の設定から決めた場所で開く。
    case open(URL, LinkBrowser)
}

extension URLMenuAction {
    /// メニューの項目。`url`がないか、開く項目で選んだ場所で開けなければ、押せないまま並べる。
    /// - Parameters:
    ///   - title: 共通の名前の代わりに出す名前。投稿のメニューで、ユーザーの項目をサブメニューにせず並べるときに使う。
    ///   - linkBrowser: 開く場所の設定。メニューを組むときの値で決める。
    public func node(title: String? = nil, url: URL?, linkBrowser: LinkBrowser) -> MenuNode<URLMenuCommand> {
        .action(title ?? self.title, icon: .symbol(symbolName), command(url: url, linkBrowser: linkBrowser))
    }

    /// 押したときの操作。押せなければnil。
    private func command(url: URL?, linkBrowser: LinkBrowser) -> URLMenuCommand? {
        guard let url else { return nil }
        switch self {
        case .copyLink:
            return .copy(url)
        case .share:
            return .share(url)
        case .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            return browser(for: url, following: linkBrowser).map { .open(url, $0) }
        }
    }
}
