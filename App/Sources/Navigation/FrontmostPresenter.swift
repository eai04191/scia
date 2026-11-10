import UIKit

extension UIViewController {
    /// この画面から重ねて出している画面のうち、いちばん手前のもの。閉じる途中の画面は数えない。
    /// 画面を出す先には使わない。閉じる途中の画面があると、その下の画面にも出せないため、`presentOnFrontmost`か`withFrontmostPresented`で出す。
    var frontmostPresented: UIViewController {
        var presenter = self
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }

    /// 重ねた画面のどれかを閉じている途中なら、閉じ終えてから`body`を呼ぶ。途中でなければ、すぐ呼ぶ。
    /// 閉じている途中は、閉じていく画面にもその下の画面にも重ねられず、UIKitが出さずに捨てる。その下の画面を閉じ始めても、閉じられずに残る。
    /// 待つ間にこの画面がなくなったら、呼ばない。
    func afterOngoingDismissal(_ body: @escaping @MainActor () -> Void) {
        var screen = presentedViewController
        while let current = screen, !current.isBeingDismissed {
            screen = current.presentedViewController
        }
        guard let dismissing = screen, let coordinator = dismissing.transitionCoordinator else {
            body()
            return
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.afterOngoingDismissal(body) }
    }
}
