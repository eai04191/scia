import UIKit

extension UIView {
    /// ウィンドウにあり、自分も祖先も隠れていない。スクロールして画面の外に出ただけのビューは含む。
    /// 読めなかった画像を、見えている間だけ読み直すのに使う（`RetrySchedule.loadWhileShown`）。
    var isInVisibleHierarchy: Bool {
        guard window != nil else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha == 0 {
                return false
            }
            view = current.superview
        }
        return true
    }
}
