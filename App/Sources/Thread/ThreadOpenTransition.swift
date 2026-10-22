import UIKit

/// スレッドを開く動き。スレッドの画面を、一覧の上に重ねて薄く出していく。
///
/// スレッドの画面は押した行を一覧で見えていた位置に置くため、押した行はそのまま残り、ほかの行だけが入れ替わって見える。
/// 横に滑らせる標準の動きでは、押した行も一緒に流れてしまう。閉じる動きは標準のままにし、端からの引き戻しで閉じられるようにする。
@MainActor
final class ThreadOpenTransition: NSObject, UIViewControllerAnimatedTransitioning {
    private let duration: TimeInterval

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        duration
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        guard let toView = transitionContext.view(forKey: .to), let toViewController = transitionContext.viewController(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        toView.frame = transitionContext.finalFrame(for: toViewController)
        toView.alpha = 0
        transitionContext.containerView.addSubview(toView)
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) {
            toView.alpha = 1
        }
        animator.addCompletion { position in
            toView.alpha = 1
            transitionContext.completeTransition(position == .end && !transitionContext.transitionWasCancelled)
        }
        animator.startAnimation()
    }
}

/// スレッドを開く間だけ、ナビゲーションの委譲先を差し替え、開く動きを渡す。開き終えたら元の委譲先に戻す。
///
/// 委譲先が`navigationController(_:animationControllerFor:from:to:)`を実装していると、`nil`を返す場合も含めて、
/// UIKitは端からと画面の中ほどからの戻るジェスチャーを始めなくなる（ドキュメントにない挙動で、Scia 1でもプロフィール画面で戻れなくなった）。
/// そのため、ふだんの委譲先にはこのメソッドを持たせず、スレッドを開く動きの間だけ、このメソッドを持つ委譲先にする。
/// 開いたあとのスレッドの画面から戻るときは、元の委譲先に戻っているので、標準の戻る動きとジェスチャーになる。
@MainActor
final class ThreadPushDelegate: NSObject, UINavigationControllerDelegate {
    private weak var base: (any UINavigationControllerDelegate)?
    private let duration: TimeInterval
    private weak var pushed: UIViewController?
    /// ナビゲーションは委譲先を弱く持つため、開き終えるまで自分を持っておく。
    private var retainSelf: ThreadPushDelegate?

    private init(base: (any UINavigationControllerDelegate)?, duration: TimeInterval) {
        self.base = base
        self.duration = duration
    }

    /// `viewController`を、一覧の上に重ねて薄く出す動きで積む。
    static func push(_ viewController: UIViewController, on navigation: UINavigationController, duration: TimeInterval) {
        let delegate = ThreadPushDelegate(base: navigation.delegate, duration: duration)
        delegate.pushed = viewController
        delegate.retainSelf = delegate
        navigation.delegate = delegate
        navigation.pushViewController(viewController, animated: true)
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        base?.navigationController?(navigationController, willShow: viewController, animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        base?.navigationController?(navigationController, didShow: viewController, animated: animated)
        navigationController.delegate = base
        retainSelf = nil
    }

    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        guard operation == .push, toVC === pushed else { return nil }
        return ThreadOpenTransition(duration: duration)
    }
}
