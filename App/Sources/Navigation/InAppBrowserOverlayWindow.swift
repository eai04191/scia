import SafariServices
import SciaCore
import SwiftUI
import UIKit

/// 全画面で開くアプリ内のSafariを載せる、アプリの上に重ねたウインドウ。
///
/// SFSafariViewControllerは、出し方（`modalPresentationStyle`か`transitioningDelegate`）を変えると、左端からのスワイプで閉じる仕組みを捨てる（iOS 27で確かめた）。
/// 読み込みの間だけ伏せたシートに重ねて見せるため、出し方は標準のままにして、Safariを入れたビューのほうをずらして切り抜く。
///
/// 伏せている間は、Safariを入れたビューを下へずらし、Safariのバーの上端をシートのSafariを出す場所に合わせる。Safariは上のセーフエリアの下にバーを描くので、セーフエリアの分はマスクで隠す。
/// 見えているところの外で触れたことは、下のウインドウへ通す。
/// Safariのバーの上には、シートと同じ引ける範囲（`InAppBrowserBarGrabView`）を、Safariより手前に置く。Safariの上で触れたことはこのウインドウの`hitTest`を通らずにSafariへ行くので、下のウインドウのシートの範囲では受けられないため。
/// 伏せている間は、そこを引くかタップすると、シートを引いたかタップしたときと同じに動く（`onBarGrabPan`、`onBarGrabTap`）。全画面に広げている間は、タップで伏せる。
/// ずらすのはウインドウではなく、UIKitがSafariを入れたビュー（Safariのビューの親）にする。ウインドウの`transform`とマスクは、`UIView.animate`で動かしても描かれる値が変わらなかった（iOS 27のシミュレーター）。
final class InAppBrowserOverlayWindow: UIWindow {
    private(set) var isCollapsed = false {
        didSet { updateBarGrab() }
    }
    /// 広げている途中。
    private(set) var isExpanding = false
    /// 見せる範囲。Safariのバーの上端から下で、その中をシートの形（`sheetShape`）で切り抜く。
    private let visibleArea = UIView()
    private let sheetShape = UIView()
    /// 伏せたままSafariを閉じ始めたときに、Safariの閉じる動きの中で呼ぶ。ここで伏せたシートを閉じると、シートの下がる動きがSafariの閉じる動きと同じ時間で動く。
    var onCollapsedDismissalBegin: (() -> Void)?
    /// Safariのバーの上の引ける範囲をタップしたときに呼ぶ。
    var onBarGrabTap: (() -> Void)?
    /// 全画面に広げている間に、タップで伏せられるか。伏せられないとき（iPhoneの横向きなど）は引ける範囲を出さない。
    /// 出すと、タップで何も起きないまま、重ねた範囲のSafariのバーのボタンを選択できなくなる。
    var canCollapse: (() -> Bool)? {
        didSet { updateBarGrab() }
    }
    /// 伏せている間に、Safariのバーの上の引ける範囲を引いたときに呼ぶ。指が動いた縦の長さと速さ（画面の座標）を渡す。
    var onBarGrabPan: ((_ state: UIGestureRecognizer.State, _ translation: CGFloat, _ velocity: CGFloat) -> Void)?
    private let barGrabView: InAppBrowserBarGrabView
    private lazy var barGrabPan = UIPanGestureRecognizer(target: self, action: #selector(handleBarGrabPan))
    /// 伏せたまま閉じる間、閉じる動きを止めているSafariの層。
    private var heldSafariLayer: CALayer?
    /// 止める前に、終わらせるよう求められた（シートを下げる時間が0のとき）。そのあとは止めない。
    private var finishedSafariDismissalHold = false

    var presenter: InAppBrowserOverlayPresenter? { rootViewController as? InAppBrowserOverlayPresenter }

    /// Safariを入れたビュー。出す前はnil。
    private var safariContainer: UIView? { presenter?.presentedViewController?.view.superview }

    private let frameSource: any FrameSource
    /// SwiftUIの`.smooth`の既定の長さ。
    private static let expandDuration: TimeInterval = 0.5

    init(windowScene: UIWindowScene, behind: @escaping () -> UIView?, barGrab: InAppBrowserBarGrab, frameSource: any FrameSource) {
        self.frameSource = frameSource
        barGrabView = InAppBrowserBarGrabView(barGrab: barGrab)
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        windowLevel = .normal + 1
        let presenter = InAppBrowserOverlayPresenter(behind: behind, frameSource: frameSource)
        rootViewController = presenter
        presenter.hostWindow = self
        // 伏せられるかは画面の向きで変わるので、引ける範囲を出すかを決め直す。
        registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) { (window: Self, _) in
            window.setNeedsLayout()
        }
        visibleArea.clipsToBounds = true
        sheetShape.backgroundColor = .black
        visibleArea.addSubview(sheetShape)
        barGrabView.isHidden = true
        barGrabView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleBarGrabTap)))
        barGrabView.addGestureRecognizer(barGrabPan)
        addSubview(barGrabView)
        AppDependencies.stateDumps.register("inAppBrowserOverlay", owner: self) { $0.stateDump() }
    }

    /// 全画面のSafariが、伏せて広げたあとにたまにステータスバーの裏まで上がって描かれる（iPhone 16 Pro）。シミュレーターでは再現しないので、起きたときの位置とセーフエリアを違和感レポートで読めるようにする。
    func stateDump() -> String {
        let safari = presenter?.presentedViewController?.viewIfLoaded
        return """
        hidden: \(isHidden) collapsed: \(isCollapsed) safeArea: \(safeAreaInsets) barGrab: hidden=\(barGrabView.isHidden) frame=\(barGrabView.frame)
        container: transform=\(safariContainer.map { "\($0.transform)" } ?? "nil") frame=\(safariContainer.map { "\($0.frame)" } ?? "nil") mask=\(safariContainer?.mask != nil)
        safari: frame=\(safari.map { "\($0.frame)" } ?? "nil") shown=\(safari?.layer.presentation().map { "\($0.frame)" } ?? "nil") safeArea=\(safari.map { "\($0.safeAreaInsets)" } ?? "nil") speed=\(safari.map { "\($0.layer.speed)" } ?? "nil") beingDismissed=\(presenter?.presentedViewController?.isBeingDismissed ?? false)
        """
    }

    /// 伏せる、広げるたびに、ログに残す値。
    var geometryLog: String {
        let safari = presenter?.presentedViewController?.viewIfLoaded
        return "windowTop=\(safeAreaInsets.top) safariFrame=\(safari.map { "\($0.frame)" } ?? "nil") safariTop=\(safari.map { "\($0.safeAreaInsets.top)" } ?? "nil") containerTy=\(safariContainer.map { "\($0.transform.ty)" } ?? "nil")"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Safariのバーの上端が画面の`safariTop`に来るように、伏せて置き、シートの形（`sheet`）で切り抜く。引ける範囲も、シートと同じ位置に置く。
    /// まだSafariを出していなければ、置けないのでfalseを返す。
    func placeCollapsed(safariTop: CGFloat, sheet: InAppBrowserSheetShape) -> Bool {
        guard let container = safariContainer else { return false }
        isCollapsed = true
        isExpanding = false
        barGrabView.frame = barGrabView.barGrab.frame(width: sheet.frame.width, safariTop: safariTop).offsetBy(dx: sheet.frame.minX, dy: 0)
        let top = safeAreaInsets.top
        let shift = safariTop - top
        container.transform = CGAffineTransform(translationX: 0, y: shift)
        visibleArea.frame = CGRect(x: 0, y: top, width: container.bounds.width, height: container.bounds.height - top)
        // 画面の座標のシートの枠を、見せる範囲の中の座標にする。
        sheetShape.frame = sheet.frame.offsetBy(dx: 0, dy: -shift - top)
        sheetShape.layer.cornerRadius = sheet.cornerRadius
        sheetShape.layer.cornerCurve = sheet.cornerCurve
        sheetShape.layer.maskedCorners = sheet.maskedCorners
        if container.mask !== visibleArea { container.mask = visibleArea }
        return true
    }

    /// 画面いっぱいから、`placeCollapsed`と同じ伏せた置き方へ縮める。
    func collapse(safariTop: CGFloat, sheet: InAppBrowserSheetShape, completion: @escaping () -> Void) {
        guard !isCollapsed, let container = safariContainer else {
            completion()
            return
        }
        // 動き始めは、画面いっぱいを見せる切り抜きにする。
        visibleArea.frame = container.bounds
        sheetShape.frame = container.bounds
        sheetShape.layer.cornerRadius = 0
        container.mask = visibleArea
        guard !UIAccessibility.isReduceMotionEnabled else {
            _ = placeCollapsed(safariTop: safariTop, sheet: sheet)
            completion()
            return
        }
        UIView.animateSpring(duration: Self.expandDuration, beginsFromCurrentState: true, in: self, frameSource: frameSource) {
            _ = self.placeCollapsed(safariTop: safariTop, sheet: sheet)
        } completion: {
            completion()
        }
    }

    /// 伏せた置き方から、画面いっぱいへ広げる。
    func expand(completion: @escaping () -> Void) {
        guard isCollapsed, let container = safariContainer else {
            completion()
            return
        }
        isCollapsed = false
        isExpanding = true
        guard !UIAccessibility.isReduceMotionEnabled else {
            container.transform = .identity
            container.mask = nil
            placeExpandedBarGrab()
            isExpanding = false
            completion()
            return
        }
        UIView.animateSpring(duration: Self.expandDuration, beginsFromCurrentState: true, in: self, frameSource: frameSource) {
            self.placeExpandedBarGrab()
            container.transform = .identity
            self.visibleArea.frame = container.bounds
            self.sheetShape.frame = container.bounds
            self.sheetShape.layer.cornerRadius = 0
        } completion: {
            // 広げる途中に伏せ直していたら、伏せた切り抜きを外さない。
            guard self.isExpanding else { return }
            self.isExpanding = false
            container.mask = nil
            completion()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 伏せる途中と広げる途中は、引ける範囲が動いている。`hitTest`は行き先の位置で判定するので、見えている位置で受ける（シートの`moveGrabTarget`と同じ）。
        if !barGrabView.isHidden, barGrabView.alpha > 0.01, (barGrabView.layer.presentation()?.frame ?? barGrabView.frame).contains(point) { return barGrabView }
        let hit = super.hitTest(point, with: event)
        if hit === barGrabView { return hit }
        if isCollapsed, let container = safariContainer {
            guard container.convert(visibleArea.frame, to: nil).contains(convert(point, to: nil)) else { return nil }
        }
        return hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isCollapsed { placeExpandedBarGrab() }
        updateBarGrab()
    }

    /// 全画面のSafariのバーは上のセーフエリアの下にあるので、引ける範囲もそこに合わせる。
    private func placeExpandedBarGrab() {
        barGrabView.frame = barGrabView.barGrab.frame(width: bounds.width, safariTop: safeAreaInsets.top)
    }

    /// Safariを出すと、UIKitがその入れ物をこのウインドウの一番手前に足すので、引ける範囲をその上へ出し直す。
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        guard subview !== barGrabView else { return }
        bringSubviewToFront(barGrabView)
        updateBarGrab()
    }

    /// 引ける範囲は、Safariを出している間に出す。全画面に広げている間は、タップで伏せられるときだけ出す。
    /// VoiceOverでは、伏せている間はシートのグラバーが受け持つので、全画面に広げている間だけ読む。引くのは伏せている間だけ。
    private func updateBarGrab() {
        barGrabView.isHidden = !barGrabView.barGrab.isEnabled || safariContainer == nil || (!isCollapsed && canCollapse?() != true)
        barGrabPan.isEnabled = isCollapsed
        barGrabView.readsAsCollapsed = isCollapsed
        barGrabView.onAccessibilityActivate = isCollapsed ? nil : { [weak self] in self?.handleBarGrabTap() }
    }

    @objc private func handleBarGrabTap() {
        guard !barGrabView.isHidden else { return }
        onBarGrabTap?()
    }

    @objc private func handleBarGrabPan(_ pan: UIPanGestureRecognizer) {
        onBarGrabPan?(pan.state, pan.translation(in: self).y, pan.velocity(in: self).y)
    }

    /// 伏せたまま閉じるとき、Safariの閉じる動き（Safariを入れたビューの中で右へ抜ける）を、動き始めの位置で止める。Safariは下がるシートに付いていくだけに見せる。
    /// 止めている間は、閉じる動きが終わらないので、Safariは閉じ終えない。シートが下がりきったら`finishHeldSafariDismissal`で終わらせる。
    /// 動きをコピーして逆向きに打ち消すと、Safariの動きとずれ、最大27pt横に動いて見えた（iOS 27のシミュレーター）。
    func holdSafariDismissalSlide() {
        guard isCollapsed, !finishedSafariDismissalHold, let safari = presenter?.presentedViewController?.viewIfLoaded else { return }
        let layer = safari.layer
        let begin = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0)?.beginTime }.filter { $0 > 0 }.min()
        let now = layer.convertTime(AppDependencies.mediaTime(), from: nil)
        layer.timeOffset = begin.map { min($0, now) } ?? now
        layer.speed = 0
        heldSafariLayer = layer
    }

    /// 止めていた閉じる動きを外し、Safariを閉じ終えさせる。
    func finishHeldSafariDismissal() {
        finishedSafariDismissalHold = true
        guard let layer = heldSafariLayer else { return }
        heldSafariLayer = nil
        layer.speed = 1
        layer.timeOffset = 0
        layer.removeAllAnimations()
    }

    /// Safariを閉じ終えてから隠す。もう閉じていれば、すぐ隠す。
    /// ×で閉じたときは、閉じる動きの前に`safariViewControllerDidFinish`が来るので、そこで隠すとSafariが動かずに消える。
    func hideAfterSafariDismissal() {
        guard let presenter, presenter.presentedViewController != nil else {
            isHidden = true
            return
        }
        // 閉じ終えるまで、ウインドウを持ち続ける。呼んだら`onSafariDismissed`を空にして、持ち合いを解く。
        presenter.onSafariDismissed = { self.isHidden = true }
    }
}

/// 重ねたウインドウで、Safariを出す元の画面。
///
/// iOSの閉じる動きは、閉じる途中でこの画面を少し左にずらした位置から付いてこさせる。この画面は透明なので、ずらした分を毎コマ読み、後ろのアプリのウインドウ（`behind`）の中を同じだけずらす。
/// スナップショットを置いて動かすと、Liquid Glassが本物と違って描かれ、閉じ終えたコマで本物に切り替わるのが見えた（iPhone 16 Proで見て確かめた）。
/// また、ProMotionの端末では、左端からのスワイプで指に付いて動く間、アプリが頼まないと60Hzで描かれる（iPhone 16 Proで録って確かめた）。閉じる動きの間は、毎コマの処理で120Hzを頼む。
final class InAppBrowserOverlayPresenter: UIViewController {
    /// Safariを閉じ終えて、この画面が出きったときに一度だけ呼ぶ。
    var onSafariDismissed: (() -> Void)?

    private let behind: () -> UIView?
    weak var hostWindow: InAppBrowserOverlayWindow?
    private let frameSource: any FrameSource
    private var dismissalFrames: FrameTicker?

    init(behind: @escaping () -> UIView?, frameSource: any FrameSource) {
        self.behind = behind
        self.frameSource = frameSource
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let coordinator = transitionCoordinator else { return }
        // 伏せたまま閉じるときは、Safariは下がるシートに付いていき、横には動かさないので、後ろの画面もずらさない。
        if let hostWindow, hostWindow.isCollapsed {
            // 指で動かす閉じ方（左端からのスワイプ）は、止めると指に付いてこないので止めない。
            guard !coordinator.isInteractive else { return }
            coordinator.animate(alongsideTransition: { [weak hostWindow] _ in
                hostWindow?.onCollapsedDismissalBegin?()
                // Safariの閉じる動きは、この時点ではまだ層に付いていないので、付いたあとに止める。
                DispatchQueue.main.async { hostWindow?.holdSafariDismissalSlide() }
            })
            return
        }
        let behind = behind()
        let ticker = FrameTicker(source: frameSource) { [weak self, weak behind] _ in
            // 動かさずに閉じてウインドウを隠したときは、閉じる動きの終わりを待たずに止める。
            guard let self, let behind, let window = self.view.window, !window.isHidden else {
                behind.map(Self.place(identityIn:))
                return false
            }
            Self.place(behind, offset: self.shownOffset)
            return true
        }
        dismissalFrames = ticker
        ticker.start()
        coordinator.animate(alongsideTransition: nil) { [weak self, weak behind] _ in
            behind.map(Self.place(identityIn:))
            self?.stopDismissalFrames()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        stopDismissalFrames()
        guard presentedViewController == nil, let onSafariDismissed else { return }
        self.onSafariDismissed = nil
        onSafariDismissed()
    }

    /// 後ろのアプリのウインドウの中を、まとめて横にずらす。ルートの画面の上に重ねたシートなどはルートの画面の外にあるので、ウインドウの中のビューを全部ずらす。
    private static func place(_ window: UIView, offset: CGFloat) {
        let transform = CGAffineTransform(translationX: offset, y: 0)
        for view in window.subviews where view.transform != transform { view.transform = transform }
    }

    private static func place(identityIn window: UIView) {
        place(window, offset: 0)
    }

    private func stopDismissalFrames() {
        dismissalFrames?.stop()
        dismissalFrames = nil
    }

    /// iOSがこの画面をずらして描いている、画面の上の横の位置。
    private var shownOffset: CGFloat {
        guard let window = view.window, let shown = view.layer.presentation(), let windowLayer = window.layer.presentation() else { return 0 }
        return shown.convert(CGPoint.zero, to: windowLayer).x
    }
}
