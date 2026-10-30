import SciaCore
import UIKit

/// 共通の項目を押したときに、メニューごとに違うところ。コピーしたことの知らせ方、共有のシートの起点、開き方。
@MainActor
struct URLMenuHandlers {
    /// 開く場所の設定。メニューを組むときの値で決める。
    let linkBrowser: LinkBrowser
    let copy: @MainActor (URL) -> Void
    let share: @MainActor (URL) -> Void
    /// `url`を、開く項目と開く場所の設定から決めた場所で開く。
    let open: @MainActor (URL, LinkBrowser) -> Void

    /// 共通の項目で選んだ操作を行う。
    func perform(_ command: URLMenuCommand) {
        switch command {
        case .copy(let url): copy(url)
        case .share(let url): share(url)
        case .open(let url, let browser): open(url, browser)
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
