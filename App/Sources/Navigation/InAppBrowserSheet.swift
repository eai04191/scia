import SafariServices
import SciaCore
import UIKit

/// アプリ内のSafariを載せるシート。Safariは帯の下を出す範囲（`area`）からモーダルで出す。実際のSafariのビューは、`area`の隣でシートの上端からいっぱいに広がる（シミュレーターで確かめた）。
///
/// Safariを入れ物の子にするのはAppleのドキュメントが禁じている。Safariは帯の下を出す範囲（`area`）からモーダルで出し、シートを動かすのは引ける範囲を引いたときだけにする。ページのスワイプでシートが動かないようにするため。
/// シートの上端からSafariのバーの真ん中までに、引ける範囲（`barGrabArea`）を重ねる。
///
/// 全画面で開くSafariが伏せている間は、Safariを持たず、帯とグラバーだけのシートにする（`safari`がnil）。Safariは`InAppBrowserOverlayWindow`から出して重ね、引ける範囲もそちらのSafariの手前に置く。
final class InAppBrowserSheet: UIViewController {
    let safari: SFSafariViewController?
    private let handleHeight: CGFloat
    private let area: UIViewController
    /// シートの上端からSafariのバーの真ん中までに重ねる、シートを引ける範囲。そこで触れたことは、シートのジェスチャーが受ける。
    let barGrabArea: InAppBrowserBarGrabView
    private let grabber = InAppBrowserGrabberView()
    /// ステータスバーを押したことを受けるスクロールビュー。UIKitは、手前に出した画面の配下のスクロールビューにしか問い合わせないため、後ろの画面にはここから渡す。
    /// 最上部にいるスクロールビューには問い合わせないので、最上部からずらしておく。`isUserInteractionEnabled`か`isScrollEnabled`を切ると問い合わせる対象に入らないので（シミュレーターで確かめた）、触れて動かないようにパンのジェスチャーだけを切る。
    private let scrollToTopReceiver = UIScrollView()
    private let clock: any Clock<Duration>
    private let safariResizeDelay: Duration
    /// シートの上端からSafariのビューまでの空き。Safariの×ボタンの上の余白を、左の余白と揃える。
    private let safariTopInset: CGFloat
    private var pendingResize: Task<Void, Never>?
    private let configuration: InAppBrowserPresentationController.Configuration
    /// 最初に止まる段。
    var initialDetent: InAppBrowserDetent = .collapsed
    /// 最初に持っておく一時スナップ点の高さ。
    var initialTemporaryHeight: Double?
    weak var presentationDelegate: (any UIAdaptivePresentationControllerDelegate)?
    private(set) weak var sheetPresentation: InAppBrowserPresentationController?
    var onPresentationCreated: ((InAppBrowserPresentationController) -> Void)?
    /// シートが動き出すかもしれないとき。このシートの上に画面を出すときと、シートが閉じ始めるとき。
    var onMayMove: (() -> Void)?

    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        onMayMove?()
        super.present(viewControllerToPresent, animated: flag, completion: completion)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onMayMove?()
    }

    init(safari: SFSafariViewController?, barGrab: InAppBrowserBarGrab, safariResizeDelay: Duration, clock: any Clock<Duration>, configuration: InAppBrowserPresentationController.Configuration) {
        self.safari = safari
        handleHeight = barGrab.handleHeight
        barGrabArea = InAppBrowserBarGrabView(barGrab: barGrab)
        self.safariResizeDelay = safariResizeDelay
        safariTopInset = barGrab.safariTopInset
        self.clock = clock
        self.configuration = configuration
        area = UIViewController()
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = self
        safari?.modalPresentationStyle = .overCurrentContext
        safari?.transitioningDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Safariの上に空けた帯が、Safariのバーと続いて見える色にする。
        view.backgroundColor = .secondarySystemBackground
        addChild(area)
        area.view.frame = CGRect(x: 0, y: handleHeight, width: view.bounds.width, height: max(0, view.bounds.height - handleHeight))
        area.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        area.definesPresentationContext = true
        view.addSubview(area.view)
        area.didMove(toParent: self)
        scrollToTopReceiver.contentSize = CGSize(width: 1, height: 3)
        scrollToTopReceiver.contentOffset.y = 1
        scrollToTopReceiver.panGestureRecognizer.isEnabled = false
        scrollToTopReceiver.delegate = self
        view.insertSubview(scrollToTopReceiver, at: 0)
    }

    /// UIKitは、押したところの真下にあるスクロールビューにだけ問い合わせる。シートがウインドウより狭い（iPad）ときも、シートの左右で押したことを受けられるよう、受け手はウインドウの幅に広げる。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.window.map { view.convert($0.bounds, from: $0) } ?? view.bounds
        scrollToTopReceiver.frame = CGRect(x: width.minX, y: 0, width: width.width, height: 1)
    }

    /// 後ろの画面を触れる状態か。全画面に広げているときと、シートの上に画面を重ねているときは触れない。
    var leavesScreenBehindUsable: Bool {
        guard sheetPresentation?.passesTouchesOutsideSheet == true else { return false }
        let front = frontmostPresented
        return front === self || front === safari
    }

    /// Safariのバーの上端の、画面の上の位置。動いている途中なら、いま描かれている位置を返す。
    var safariTopOnScreen: CGFloat? {
        guard let window = view.window else { return nil }
        // Safariは`area`から出すが、置かれるのは`area`ではなくシートの上端から`safariTopInset`だけ下（`placeSafari`）。
        return window.convert(view.convert(CGPoint(x: 0, y: safariTopInset), to: window), to: nil).y + movingOffset
    }

    /// シートが動いている途中の、いま描かれている上端と、行き着く上端との差。
    private var movingOffset: CGFloat {
        guard let visible = view.layer.presentation()?.frame else { return 0 }
        return visible.minY - view.frame.minY
    }

    /// シートの形。画面の上の枠と、角の丸み。動いている途中なら、いま描かれている形。
    var shapeOnScreen: InAppBrowserSheetShape? {
        guard let window = view.window, let superview = view.superview else { return nil }
        let visible = view.layer.presentation()?.frame ?? view.frame
        let frame = window.convert(superview.convert(visible, to: window), to: nil)
        return InAppBrowserSheetShape(frame: frame, cornerRadius: view.layer.cornerRadius, cornerCurve: view.layer.cornerCurve, maskedCorners: view.layer.maskedCorners)
    }

    /// シートが止まったら呼ぶ。少し待って、続けて変わる行き先を1回の変更にまとめる。
    func resizeSafari(toHeight height: CGFloat) {
        pendingResize?.cancel()
        pendingResize = Task(.withoutRequests) { [weak self, clock, safariResizeDelay] in
            do {
                try await clock.sleep(for: safariResizeDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.placeSafari(sheetHeight: height)
        }
    }

    /// Safariの下端をシートの`sheetHeight`の位置に合わせ、上端を`safariTopInset`だけ下げる。
    private func placeSafari(sheetHeight: CGFloat) {
        guard let safari, let container = safari.viewIfLoaded?.superview else { return }
        safari.view.frame = CGRect(x: container.bounds.minX, y: container.bounds.minY + safariTopInset, width: container.bounds.width, height: sheetHeight - safariTopInset)
    }

    /// シートをつかんだら呼ぶ。引いている間はSafariの大きさを変えない。
    func cancelSafariResize() {
        pendingResize?.cancel()
    }

    /// シートを出し始めたあとに呼んで、帯の下にSafariを重ね、その上にSafariのバーの引ける範囲を重ねる。シートと一緒に上がってくるよう、Safariは動かさずに出す。
    func presentSafari() {
        if let safari { area.present(safari, animated: false) }
        // 待ってから動かすと、出したあとにSafariが下がって見えるため、すぐ置く。
        if let height = sheetPresentation?.safariSheetHeight { placeSafari(sheetHeight: height) }
        let width = view.bounds.width
        grabber.frame = CGRect(x: (width - 36) / 2, y: 5, width: 36, height: 5)
        grabber.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        grabber.presentation = sheetPresentation
        view.addSubview(grabber)
        // Safariを持たないシート（全画面で開くSafariが伏せている間）では、重ねたウインドウのSafariの手前に置く（`InAppBrowserOverlayWindow`）。
        guard safari != nil, barGrabArea.barGrab.isEnabled else { return }
        barGrabArea.frame = barGrabArea.barGrab.frame(width: width, safariTop: safariTopInset)
        barGrabArea.autoresizingMask = [.flexibleWidth]
        view.addSubview(barGrabArea)
    }
}

/// シートのグラバー。VoiceOverでは押すと次の段へ動かす。
private final class InAppBrowserGrabberView: UIView {
    weak var presentation: InAppBrowserPresentationController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiaryLabel
        layer.cornerRadius = 2.5
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = InAppBrowserSheetTexts.grabber
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var accessibilityValue: String? {
        get { InAppBrowserSheetTexts.grabberValue(isCollapsed: presentation?.selected == .collapsed) }
        set { _ = newValue }
    }

    override func accessibilityActivate() -> Bool {
        presentation?.selectNextDetent()
        return presentation != nil
    }
}

extension InAppBrowserSheet: UIScrollViewDelegate {
    /// 後ろの画面が見えている間は、後ろの画面でステータスバーを押したときと同じく、見えているスクロールビューを最上部へ動かす。全画面では何もしない。
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard sheetPresentation?.passesTouchesOutsideSheet == true, let behind = presentingViewController?.viewIfLoaded else { return false }
        for target in behind.scrollViewsScrollingToTop() where target.delegate?.scrollViewShouldScrollToTop?(target) ?? true {
            target.setContentOffset(CGPoint(x: target.contentOffset.x, y: -target.adjustedContentInset.top), animated: true)
        }
        return false
    }
}

extension InAppBrowserSheet: UIViewControllerTransitioningDelegate {
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        guard presented === self else { return nil }
        let controller = InAppBrowserPresentationController(presented: self, presenting: presenting, selected: initialDetent, temporaryHeight: initialTemporaryHeight, configuration: configuration)
        controller.delegate = presentationDelegate
        sheetPresentation = controller
        onPresentationCreated?(controller)
        return controller
    }

    /// Safariは動きなしで出すので、シートの動きだけを持つ（`presentSafari`）。
    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        presented === self ? InAppBrowserSheetTransition(isPresenting: true, duration: configuration.duration()) : nil
    }

    /// Safariの×で閉じるときは、Safariだけを閉じず、シートごと閉じる。Safariだけを閉じると、帯だけの空のシートが残るため。
    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        if dismissed === self { return InAppBrowserSheetTransition(isPresenting: false, duration: configuration.duration()) }
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

/// シートの形。全画面で開くSafariを読み込む間に、重ねたSafariをこの形で切り抜く。
struct InAppBrowserSheetShape {
    var frame: CGRect
    var cornerRadius: CGFloat
    var cornerCurve: CALayerCornerCurve
    var maskedCorners: CACornerMask
}
