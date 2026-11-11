import SafariServices
import SciaCore
import UIKit

/// アプリ内のSafariを載せるシート。Safariは帯の下を出す範囲（`area`）からモーダルで出す。実際のSafariのビューは、`area`の隣でシートの上端からいっぱいに広がる（シミュレーターで確かめた）。
///
/// Safariを入れ物の子にするのはAppleのドキュメントが禁じている。Safariは帯の下を出す範囲（`area`）からモーダルで出し、シートを動かすのは引ける範囲を引いたときだけにする。ページのスワイプでシートが動かないようにするため。
/// シートの上端からSafariのバーの真ん中までに、引ける範囲（`barGrabArea`）を重ねる。
final class InAppBrowserSheet: UIViewController {
    let safari: SFSafariViewController
    private let handleHeight: CGFloat
    private let area: UIViewController
    /// シートの上端からSafariのバーの真ん中までに重ねる、シートを引ける範囲。Safariの上で触れたことはSafariのプロセスへ行くが、上に自分のビューを重ねると、そこで触れたことはアプリに届き、シートのジェスチャーが受ける。
    /// 色のない（完全に透明な）ビューでは、触れたことが重ねたビューを通り抜けてSafariへ行き、シートを引けない（シミュレーターで確かめた）。そのため、見た目にはわからない濃さの色を付ける。
    /// Safariのバーとページは別のプロセスが描いていて、アプリからはどちらの上かを触れた場所で選び分けられないので、範囲の高さと左右の空きはチューニングで決める。
    let barGrabArea = UIView()
    private let grabber = InAppBrowserGrabberView()
    private let barGrab: BarGrab
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

    /// Safariのバーの上に重ねる、シートを引ける範囲の決まり。
    struct BarGrab {
        var height: CGFloat
        var inset: CGFloat
        /// 範囲がどこにあるかを確かめるために、見える色で塗る。
        var isVisible: Bool
    }

    init(safari: SFSafariViewController, handleHeight: CGFloat, barGrab: BarGrab, safariResizeDelay: Duration, safariTopInset: CGFloat, clock: any Clock<Duration>, configuration: InAppBrowserPresentationController.Configuration) {
        self.safari = safari
        self.handleHeight = handleHeight
        self.barGrab = barGrab
        self.safariResizeDelay = safariResizeDelay
        self.safariTopInset = safariTopInset
        self.clock = clock
        self.configuration = configuration
        area = UIViewController()
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = self
        safari.modalPresentationStyle = .overCurrentContext
        safari.transitioningDelegate = self
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
    }

    /// 後ろの画面を触れる状態か。全画面に広げているときと、シートの上に画面を重ねているときは触れない。
    var leavesScreenBehindUsable: Bool {
        guard sheetPresentation?.passesTouchesOutsideSheet == true else { return false }
        let front = frontmostPresented
        return front === self || front === safari
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
        guard let container = safari.viewIfLoaded?.superview else { return }
        safari.view.frame = CGRect(x: container.bounds.minX, y: container.bounds.minY + safariTopInset, width: container.bounds.width, height: sheetHeight - safariTopInset)
    }

    /// シートをつかんだら呼ぶ。引いている間はSafariの大きさを変えない。
    func cancelSafariResize() {
        pendingResize?.cancel()
    }

    /// シートを出し始めたあとに呼んで、帯の下にSafariを重ね、その上にSafariのバーの引ける範囲を重ねる。シートと一緒に上がってくるよう、Safariは動かさずに出す。
    func presentSafari() {
        area.present(safari, animated: false)
        // 待ってから動かすと、出したあとにSafariが下がって見えるため、すぐ置く。
        if let height = sheetPresentation?.safariSheetHeight { placeSafari(sheetHeight: height) }
        let width = view.bounds.width
        grabber.frame = CGRect(x: (width - 36) / 2, y: 5, width: 36, height: 5)
        grabber.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin]
        grabber.presentation = sheetPresentation
        view.addSubview(grabber)
        guard barGrab.height > 0 else { return }
        barGrabArea.backgroundColor = barGrab.isVisible ? UIColor.systemRed.withAlphaComponent(0.4) : UIColor.black.withAlphaComponent(0.01)
        barGrabArea.frame = CGRect(x: barGrab.inset, y: 0, width: max(0, width - barGrab.inset * 2), height: safariTopInset + handleHeight + barGrab.height)
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
        accessibilityLabel = "シートグラバー"
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var accessibilityValue: String? {
        get { presentation?.selected == .collapsed ? "折りたたまれました" : "広げられました" }
        set { _ = newValue }
    }

    override func accessibilityActivate() -> Bool {
        presentation?.selectNextDetent()
        return presentation != nil
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
