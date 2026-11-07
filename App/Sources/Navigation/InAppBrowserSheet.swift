import SafariServices
import UIKit

/// アプリ内のSafariを載せるシート。シートの上端に引く帯を置き、Safariは帯の下の範囲にモーダルで重ねる。
///
/// Safariをそのままシートで出すと、ページを下へスワイプしたときに、Safariのプロセスがシートを引き下げる。
/// `prefersScrollingExpandsWhenScrolledToEdge`では止まらず、Safariを入れ物の子にするのはAppleのドキュメントが禁じている。
/// シートを持つのをこの画面にして、Safariは帯の下を出す範囲（`area`）からモーダルで出すと、Safariからはシートを動かせなくなり、引けるのは帯だけになる。
/// 帯をSafariのバーの上に透明に重ねる形も試したが、そこからはシートを引けなかった。
final class InAppBrowserSheet: UIViewController {
    let safari: SFSafariViewController
    private let handleHeight: CGFloat
    private let area: UIViewController

    init(safari: SFSafariViewController, handleHeight: CGFloat) {
        self.safari = safari
        self.handleHeight = handleHeight
        area = UIViewController()
        super.init(nibName: nil, bundle: nil)
        safari.modalPresentationStyle = .overCurrentContext
        safari.transitioningDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        addChild(area)
        area.view.frame = CGRect(x: 0, y: handleHeight, width: view.bounds.width, height: max(0, view.bounds.height - handleHeight))
        area.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        area.definesPresentationContext = true
        view.addSubview(area.view)
        area.didMove(toParent: self)
    }

    /// シートを出し始めたあとに呼んで、帯の下にSafariを重ねる。シートと一緒に上がってくるよう、Safariは動かさずに出す。
    func presentSafari() {
        area.present(safari, animated: false)
    }
}

extension InAppBrowserSheet: UIViewControllerTransitioningDelegate {
    /// 出すときは動かさないので、UIKitに任せる（`presentSafari`は動きなしで出す）。
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        nil
    }

    /// Safariの×で閉じるときは、Safariだけを閉じず、シートごと閉じる。Safariだけを閉じると、帯だけの空のシートが残るため。
    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        guard dismissed === safari else { return nil }
        return SheetClosingTransition(sheet: self)
    }
}

/// Safariを閉じる遷移の間、Safariをその場に残してシートを閉じ、シートが下がりきってから遷移を終える。Safariはシートと一緒に下がる。
private final class SheetClosingTransition: NSObject, UIViewControllerAnimatedTransitioning {
    private weak var sheet: InAppBrowserSheet?

    init(sheet: InAppBrowserSheet) {
        self.sheet = sheet
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        guard let sheet, let presenter = sheet.presentingViewController, !sheet.isBeingDismissed else {
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            return
        }
        presenter.dismiss(animated: transitionContext.isAnimated) {
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        }
    }
}
