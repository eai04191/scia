import SafariServices
import SciaCore
import SwiftUI
import UIKit

/// 全画面で開くアプリ内のSafariを載せる、アプリの上に重ねたウインドウ。
///
/// SFSafariViewControllerは、出し方（`modalPresentationStyle`か`transitioningDelegate`）を変えると、左端からのスワイプで閉じる仕組みを捨てる（iOS 27で確かめた）。
/// 読み込みの間だけ伏せたシートに重ねて見せるため、出し方は標準のままにして、Safariを入れたビューのほうをずらして切り抜く。
///
/// 伏せている間は、Safariを入れたビューを下へずらし、Safariのバーの上端をシートのSafariを出す場所に合わせる。Safariは上の安全領域の下にバーを描くので、安全領域の分はマスクで隠す。
/// 見えているところの外で触れたことは、下のウインドウへ通す。
/// ずらすのはウインドウではなく、UIKitがSafariを入れたビュー（Safariのビューの親）にする。ウインドウの`transform`とマスクは、`UIView.animate`で動かしても描かれる値が変わらなかった（iOS 27のシミュレーター）。
final class InAppBrowserOverlayWindow: UIWindow {
    private(set) var isCollapsed = false
    /// 見せる範囲。Safariのバーの上端から下で、その中をシートの形（`sheetShape`）で切り抜く。
    private let visibleArea = UIView()
    private let sheetShape = UIView()
    /// 伏せている間に、下のウインドウへ通すところ（シートのバーを引ける範囲）。画面の座標。
    private var passthroughRect: CGRect = .null

    var presenter: InAppBrowserOverlayPresenter? { rootViewController as? InAppBrowserOverlayPresenter }

    /// Safariを入れたビュー。出す前はnil。
    private var safariContainer: UIView? { presenter?.presentedViewController?.view.superview }

    private let frameSource: any FrameSource

    init(windowScene: UIWindowScene, behind: @escaping () -> UIView?, frameSource: any FrameSource) {
        self.frameSource = frameSource
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        windowLevel = .normal + 1
        rootViewController = InAppBrowserOverlayPresenter(behind: behind, frameSource: frameSource)
        visibleArea.clipsToBounds = true
        sheetShape.backgroundColor = .black
        visibleArea.addSubview(sheetShape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Safariのバーの上端が画面の`safariTop`に来るように、伏せて置き、シートの形（`sheet`）で切り抜く。`passthrough`はシートのバーを引ける範囲（画面の座標）。
    /// まだSafariを出していなければ、置けないのでfalseを返す。
    func placeCollapsed(safariTop: CGFloat, sheet: InAppBrowserSheetShape, passthrough: CGRect) -> Bool {
        guard let container = safariContainer else { return false }
        isCollapsed = true
        passthroughRect = passthrough
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

    /// 伏せた置き方から、画面いっぱいへ広げる。
    /// 広げる動きの間は、閉じる動きと同じく120Hzを頼む（`InAppBrowserOverlayPresenter`）。頼まないと60Hzで描かれることがある。
    func expand(completion: @escaping () -> Void) {
        guard isCollapsed, let container = safariContainer else {
            completion()
            return
        }
        isCollapsed = false
        passthroughRect = .null
        guard !UIAccessibility.isReduceMotionEnabled else {
            container.transform = .identity
            container.mask = nil
            completion()
            return
        }
        let highFrameRate = FrameTicker(source: frameSource) { [weak self] _ in self?.isHidden == false }
        highFrameRate.start()
        UIView.animate(.smooth) {
            container.transform = .identity
            self.visibleArea.frame = container.bounds
            self.sheetShape.frame = container.bounds
            self.sheetShape.layer.cornerRadius = 0
        } completion: {
            highFrameRate.stop()
            container.mask = nil
            completion()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isCollapsed, let container = safariContainer {
            let onScreen = convert(point, to: nil)
            guard container.convert(visibleArea.frame, to: nil).contains(onScreen), !passthroughRect.contains(onScreen) else { return nil }
        }
        return super.hitTest(point, with: event)
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
