import SciaCore
import UIKit

/// 投稿、ユーザー、リンク、ハッシュタグのメニューに共通の、ページのURLに対する項目。
/// どのメニューに置くかはメニューごとの項目の一覧で決め、ここでは名前と印と、押せる状態かどうかと、開く項目がどこで開くかをそろえる。
enum URLMenuAction {
    case copyLink
    case share
    /// 開く場所の設定に従って開く。リンクをタップしたときと同じ。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。
    case openInAppSafari

    var title: String {
        switch self {
        case .copyLink: "リンクをコピー"
        case .share: "共有"
        case .openInBrowser: "ブラウザで開く"
        case .openInDefaultBrowser: "既定のブラウザで開く"
        case .openInAppSafari: "アプリ内のSafariで開く"
        }
    }

    var symbolName: String {
        switch self {
        case .copyLink: "link"
        case .share: "square.and.arrow.up"
        case .openInBrowser: "safari"
        case .openInDefaultBrowser: "arrow.up.forward.app"
        case .openInAppSafari: "rectangle.bottomhalf.inset.filled"
        }
    }

    var image: UIImage? { UIImage(systemName: symbolName) }

    /// 開く項目で`url`を開く場所。その場所で開けなければnil。
    func browser(for url: URL, following setting: LinkBrowser) -> LinkBrowser? {
        switch self {
        case .openInBrowser: setting.browser(for: url)
        case .openInDefaultBrowser: .external
        // アプリ内のSafariは、httpとhttps以外のURLを渡すと例外で落ちる。黙って既定のブラウザで開くと選んだ場所と違うため、押せないようにする。
        case .openInAppSafari: LinkBrowser.inApp.browser(for: url) == .inApp ? .inApp : nil
        case .copyLink, .share: nil
        }
    }

    /// 開く項目。`url`がないか、選んだ場所で開けなければ、押せないまま並べる。
    /// - Parameter setting: 開く場所の設定。メニューを組むときの値で決める。
    @MainActor
    func openAction(title: String? = nil, url: URL?, following setting: LinkBrowser, open: @escaping @MainActor (URL, LinkBrowser) -> Void) -> UIAction {
        let target = url.flatMap { url in browser(for: url, following: setting).map { (url: url, browser: $0) } }
        return UIAction(title: title ?? self.title, image: image, attributes: target == nil ? .disabled : []) { _ in
            guard let target else { return }
            open(target.url, target.browser)
        }
    }

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
