import SciaCore
import UIKit

/// 投稿、ユーザー、リンク、ハッシュタグのメニューに共通の、ページのURLに対する項目。
/// どのメニューに置くかはメニューごとの項目の一覧で決め、ここでは名前とアイコンと、押せる状態かどうかと、開く項目がどこで開くかをそろえる。
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

    /// 並びの設定画面で、名前の下に添える説明。メニューに固有の決まりがあれば、メニューの側でこれに書き足す。
    var note: String? {
        switch self {
        case .openInBrowser: "設定の開く場所で開きます"
        case .openInDefaultBrowser: "設定の開く場所にかかわらず、既定のブラウザで開きます"
        case .openInAppSafari: "設定の開く場所にかかわらず、アプリ内のSafariで開きます"
        case .copyLink, .share: nil
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

    /// メニューの項目。`url`がないか、開く項目で選んだ場所で開けなければ、押せないまま並べる。
    /// - Parameter title: 共通の名前の代わりに出す名前。投稿のメニューで、ユーザーの項目をサブメニューにせず並べるときに使う。
    @MainActor
    func action(title: String? = nil, url: URL?, handlers: URLMenuHandlers) -> UIAction {
        switch self {
        case .copyLink:
            simpleAction(title: title, url: url, perform: handlers.copy)
        case .share:
            simpleAction(title: title, url: url, perform: handlers.share)
        case .openInBrowser, .openInDefaultBrowser, .openInAppSafari:
            openAction(title: title, url: url, following: handlers.linkBrowser, open: handlers.open)
        }
    }

    @MainActor
    private func openAction(title: String?, url: URL?, following setting: LinkBrowser, open: @escaping @MainActor (URL, LinkBrowser) -> Void) -> UIAction {
        let target = url.flatMap { url in browser(for: url, following: setting).map { (url: url, browser: $0) } }
        return UIAction(title: title ?? self.title, image: image, attributes: target == nil ? .disabled : []) { _ in
            guard let target else { return }
            open(target.url, target.browser)
        }
    }

    @MainActor
    private func simpleAction(title: String?, url: URL?, perform: @escaping @MainActor (URL) -> Void) -> UIAction {
        UIAction(title: title ?? self.title, image: image, attributes: url == nil ? .disabled : []) { _ in
            guard let url else { return }
            perform(url)
        }
    }
}

/// 共通の項目を押したときに、メニューごとに違うところ。コピーしたことの知らせ方、共有のシートの起点、開き方。
@MainActor
struct URLMenuHandlers {
    /// 開く場所の設定。メニューを組むときの値で決める。
    let linkBrowser: LinkBrowser
    let copy: @MainActor (URL) -> Void
    let share: @MainActor (URL) -> Void
    /// `url`を、開く項目と開く場所の設定から決めた場所で開く。
    let open: @MainActor (URL, LinkBrowser) -> Void
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
