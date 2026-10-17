import UIKit

extension UIViewController {
    /// この画面から重ねて出している画面のうち、いちばん手前のもの。閉じる途中の画面には重ねない。
    /// アプリ内のSafariのシートを出したまま、一覧からビューアなどを開くときに、シートの上へ重ねるために使う。
    var frontmostPresented: UIViewController {
        var presenter = self
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }
}
