import SafariServices
import SciaCore
import UIKit

/// アプリ内のSafariを載せるシート。Safariは帯の下を出す範囲（`area`）からモーダルで出す。実際のSafariのビューは、`area`の隣でシートの上端からいっぱいに広がる（シミュレーターで確かめた）。
///
/// Safariをそのままシートで出すと、ページを下へスワイプしたときに、Safariのプロセスがシートを引き下げる。
/// `prefersScrollingExpandsWhenScrolledToEdge`では止まらず、Safariを入れ物の子にするのはAppleのドキュメントが禁じている。
/// シートを持つのをこの画面にして、Safariは帯の下を出す範囲（`area`）からモーダルで出すと、Safariからはシートを動かせなくなり、引けるのは帯だけになる。
/// シートの上端からSafariのバーの真ん中までに、引ける範囲（`barGrabArea`）を重ねる。
final class InAppBrowserSheet: UIViewController {
    let safari: SFSafariViewController
    private let handleHeight: CGFloat
    private let area: UIViewController
    /// シートの上端からSafariのバーの真ん中までに重ねる、シートを引ける範囲。Safariの上で触れたことはSafariのプロセスへ行くが、上に自分のビューを重ねると、そこで触れたことはアプリに届き、シートのジェスチャーが受ける。
    /// 色のない（完全に透明な）ビューでは、触れたことが重ねたビューを通り抜けてSafariへ行き、シートを引けない（シミュレーターで確かめた）。そのため、見た目にはわからない濃さの色を付ける。
    /// Safariのバーとページは別のプロセスが描いていて、アプリからはどちらの上かを触れた場所で選び分けられないので、範囲の高さと左右の空きはチューニングで決める。
    let barGrabArea = UIView()
    private let barGrab: BarGrab
    private let clock: any Clock<Duration>
    private var narrowing: Task<Void, Never>?
    private let safariResizeDelay: Duration
    private var pendingResize: Task<Void, Never>?
    private lazy var fingerWatcher = FingerWatcher { [weak self] isDown in
        self?.isFingerDown = isDown
    }
    var isWatchingFinger: Bool { fingerWatcher.view != nil }
    /// アプリのウィンドウに指が触れている間。Safariの上の指はウィンドウに届かないので、シートを引く指はここに入るが、ページを触る指は入らない。
    var isFingerDown = false {
        didSet {
            if oldValue, !isFingerDown { view.setNeedsLayout() }
        }
    }

    /// Safariのバーの上に重ねる、シートを引ける範囲の決まり。
    struct BarGrab {
        var height: CGFloat
        var inset: CGFloat
        /// シートの段が変わった直後の高さと、その高さを保つ時間。
        var settlingHeight: CGFloat
        var settlingDuration: Duration
        /// 範囲がどこにあるかを確かめるために、見える色で塗る。
        var isVisible: Bool
    }

    init(safari: SFSafariViewController, handleHeight: CGFloat, barGrab: BarGrab, safariResizeDelay: Duration, clock: any Clock<Duration>) {
        self.safari = safari
        self.handleHeight = handleHeight
        self.barGrab = barGrab
        self.safariResizeDelay = safariResizeDelay
        self.clock = clock
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

    /// シートの段が変わったら、Safariを載せている枠いっぱいに広げる。Safariのビューは大きさの追従（autoresizing）を持たず、
    /// 出したときの大きさのまま残って、広げたシートの下が空くため。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard safari.presentingViewController != nil, let container = safari.viewIfLoaded?.superview else { return }
        scheduleSafariResize(toFit: container)
    }

    /// 指が触れている間は待ち、離したあとは少し待って、続けて変わるシートの大きさを1回の変更にまとめる。
    /// 毎フレーム変えると、離してから0.7秒ほどSafariがタップを受けない（シミュレーターで確かめた）。代わりに、引いている途中はSafariがシートに付いてこない。
    private func scheduleSafariResize(toFit container: UIView) {
        pendingResize?.cancel()
        guard !isFingerDown, safari.view.frame != container.bounds else { return }
        pendingResize = Task(.withoutRequests) { [weak self, weak container, clock, safariResizeDelay] in
            do {
                try await clock.sleep(for: safariResizeDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, !self.isFingerDown, let container else { return }
            self.safari.view.frame = container.bounds
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard fingerWatcher.view == nil else { return }
        view.window?.addGestureRecognizer(fingerWatcher)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        fingerWatcher.view?.removeGestureRecognizer(fingerWatcher)
        isFingerDown = false
    }

    /// シートを出し始めたあとに呼んで、帯の下にSafariを重ね、その上にSafariのバーの引ける範囲を重ねる。シートと一緒に上がってくるよう、Safariは動かさずに出す。
    func presentSafari() {
        area.present(safari, animated: false)
        guard barGrab.height > 0 else { return }
        barGrabArea.backgroundColor = barGrab.isVisible ? UIColor.systemRed.withAlphaComponent(0.4) : UIColor.black.withAlphaComponent(0.01)
        barGrabArea.frame = CGRect(x: barGrab.inset, y: 0, width: max(0, view.bounds.width - barGrab.inset * 2), height: handleHeight + barGrab.height)
        barGrabArea.autoresizingMask = [.flexibleWidth]
        view.addSubview(barGrabArea)
    }

    /// シートの段が変わったら呼んで、シートが動いている間だけ、引ける範囲を下へ広げる。動いている間は範囲も画面の上で動くので、続けて触れた指が範囲を外れると、触れたことはSafariへ行き、シートを引けない。
    /// 引いたあとに同じ段へ戻ったときは、段の変化が届かないので広げない。そのときに続けて触れると範囲を外れることがあるが、知る手段はシートのジェスチャーを探すことになり、非公開の作りに頼るため対応しない。
    func widenBarGrabAreaWhileSettling() {
        guard barGrabArea.superview != nil else { return }
        barGrabArea.frame.size.height = handleHeight + max(barGrab.height, barGrab.settlingHeight)
        narrowing?.cancel()
        narrowing = Task(.withoutRequests) { [weak self, clock, barGrab, handleHeight] in
            do {
                try await clock.sleep(for: barGrab.settlingDuration)
            } catch {
                return
            }
            // 待ち終えてから続きが走るまでに次の段の変化が届いても、広げ直した範囲を戻さない。
            guard !Task.isCancelled else { return }
            self?.barGrabArea.frame.size.height = handleHeight + barGrab.height
        }
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

/// ウィンドウに指が触れているかだけを見るジェスチャー。何も認識せず、ほかのジェスチャーやビューの操作を邪魔しない。
private final class FingerWatcher: UIGestureRecognizer {
    private let onChange: (Bool) -> Void
    private var activeTouches = 0

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if activeTouches == 0 { onChange(true) }
        activeTouches += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        release(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        release(touches)
    }

    private func release(_ touches: Set<UITouch>) {
        activeTouches -= touches.count
        guard activeTouches <= 0 else { return }
        activeTouches = 0
        onChange(false)
        state = .failed
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
