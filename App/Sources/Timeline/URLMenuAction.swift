import UIKit

/// 投稿、ユーザー、リンク、ハッシュタグのメニューに共通の、ページのURLに対する項目。
/// どのメニューに置くかはメニューごとの項目の一覧で決め、ここでは名前と印と、押せる状態かどうかの決め方をそろえる。
/// 「ブラウザで開く」は名前と印だけを共有し、押したときの動きはメニューごとに渡す。
/// 投稿のメニューでは開く場所の設定に従い、リンクとハッシュタグのメニューでは設定にかかわらず既定のブラウザで開くため。
enum URLMenuAction {
    case copyLink
    case share
    case openInBrowser

    var title: String {
        switch self {
        case .copyLink: "リンクをコピー"
        case .share: "共有"
        case .openInBrowser: "ブラウザで開く"
        }
    }

    var symbolName: String {
        switch self {
        case .copyLink: "link"
        case .share: "square.and.arrow.up"
        case .openInBrowser: "safari"
        }
    }

    var image: UIImage? { UIImage(systemName: symbolName) }

    /// メニューの項目。`url`がなければ押せないまま並べる。
    /// - Parameter title: 共通の名前の代わりに出す名前。投稿のメニューで、ユーザーの項目をサブメニューにせず並べるときに使う。
    @MainActor
    func menuAction(title: String? = nil, url: URL?, perform: @escaping @MainActor (URL) -> Void) -> UIAction {
        UIAction(title: title ?? self.title, image: image, attributes: url == nil ? .disabled : []) { _ in
            guard let url else { return }
            perform(url)
        }
    }
}

/// メニューで選んだURLの、コピーと共有。
@MainActor
enum URLSharing {
    /// クリップボードに入れ、コピーしたことを`host`の画面に知らせる。
    static func copy(_ url: URL, notifying host: (any LinkMenuHost)?) {
        UIPasteboard.general.url = url
        host?.showLinkCopiedNotice()
    }

    /// 共有のシートを出す。iPadとMacではポップオーバーで出るため、起点を`anchor`で決める。
    static func presentShareSheet(for url: URL, from presenter: UIViewController, anchor: (UIPopoverPresentationController) -> Void) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            anchor(popover)
        }
        // アプリ内のSafariのシートを出したまま上の一覧から共有することがあるため、いちばん手前の画面から出す。
        presenter.frontmostPresented.present(activity, animated: true)
    }
}
