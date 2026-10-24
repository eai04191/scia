import UIKit

extension UIViewController {
    /// 共有で投稿欄に入れるときに、投稿欄を隠している画面のうち、見るためだけの画面（ビューアとメニュー）を閉じる。閉じ終えたら`completion`を呼ぶ。
    /// 手前から順に閉じられる画面だけを閉じ、閉じない画面（設定やプロフィールの編集、確認のアラートなど）に当たったら、その上までで止める。
    /// 閉じない画面は、書いていたものや選びかけのものを、使う人が選ばずに失うため。
    func closeScreensForSharedContent(completion: @escaping () -> Void) {
        var chain: [UIViewController] = []
        var current = self
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            chain.append(presented)
            current = presented
        }
        let closable = chain.reversed().prefix { $0.closesForSharedContent }
        guard let lowest = closable.last else {
            completion()
            return
        }
        if let viewer = lowest as? MediaViewerController {
            viewer.closeForSharedContent(dismissed: completion)
        } else if let presenter = lowest.presentingViewController {
            presenter.dismiss(animated: true, completion: completion)
        } else {
            completion()
        }
    }

    /// 共有で投稿欄に入れるときに閉じる画面か。
    private var closesForSharedContent: Bool {
        if self is MediaViewerController { return true }
        // 投稿やリンクの長押しのメニューと、ボタンのメニューは、UIKitの非公開の画面（`_UIContextMenuActionsOnlyViewController`など）として重なる。
        // 公開の型がないので名前で見分ける。iOSが名前を変えたら、メニューは閉じずに残り、投稿欄はメニューの奥で書き始める。
        return NSStringFromClass(type(of: self)).hasPrefix("_UIContextMenu")
    }
}
