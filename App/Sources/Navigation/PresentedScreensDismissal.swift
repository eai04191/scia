import UIKit

extension UIViewController {
    /// 上に重ねた画面をまとめて閉じ、閉じ終えたら、閉じた画面に下へスワイプして閉じたときと同じ知らせ（`presentationControllerDidDismiss`）を送る。
    /// 出した側から閉じると、UIKitはこの知らせを送らず、閉じた画面の`dismiss`も通らない。シートはどれもスワイプで閉じたときの後始末をこの知らせで行うので、
    /// 重ねた画面をまとめて閉じるときはこれを通し、画面ごとにまとめて閉じられたときの扱いを足さずに済ませる。
    /// 閉じていく途中の画面と、その上の画面には送らない。閉じ始めた側が、閉じたことを知らせるため。知らせは、UIKitが閉じる順と同じく手前の画面から送る。
    func dismissPresentedScreens(animated: Bool, completion: (() -> Void)? = nil) {
        var presentations: [UIPresentationController] = []
        var current = self
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            if let presentation = presented.presentationController {
                presentations.append(presentation)
            }
            current = presented
        }
        guard !presentations.isEmpty else {
            completion?()
            return
        }
        dismiss(animated: animated) {
            for presentation in presentations.reversed() {
                presentation.delegate?.presentationControllerDidDismiss?(presentation)
            }
            completion?()
        }
    }
}
