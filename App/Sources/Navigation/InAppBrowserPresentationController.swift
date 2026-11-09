import SciaCore
import SwiftUI
import UIKit

/// アプリ内のSafariのシートの出し方。UIKitのシートは低い段で幅を縮めて下端から浮かせ、止める公開APIがないので、画面の幅いっぱいのシートを自分で動かす。
/// シートのビューは全画面の高さのまま位置だけを動かす。Safariの大きさを毎フレーム変えると、離してから0.7秒ほどSafariがタップを受けないため（シミュレーターで確かめた）。
@MainActor
final class InAppBrowserPresentationController: UIPresentationController {
    struct Configuration {
        var cornerRadius: CGFloat
        var duration: TimeInterval
        var maximumWidth: CGFloat
        var maximumDimAlpha: CGFloat
        /// 指がこの秒数だけ`snapTolerance`の範囲にとどまったら、スナップ点を作る。
        var snapDwell: Duration
        var snapTolerance: CGFloat
        var clock: any Clock<Duration>
        var layout: (UIWindow, UITraitCollection) -> InAppBrowserSheetLayout
    }

    private let configuration: Configuration
    private let dimming = UIView()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    private(set) var selected: InAppBrowserDetent
    /// 指で段を変えたとき。
    var onSelectionChange: (() -> Void)?
    /// 画面の回転などで、段の高さが変わったとき。
    var onLayoutChange: (() -> Void)?
    private var lastBaseLayout: InAppBrowserSheetLayout?
    /// 指を止めて作ったスナップ点。ほかの段へ動かすと消える。
    private(set) var temporaryHeight: Double?
    private var dwell: Task<Void, Never>?
    private var dwellAnchorHeight: CGFloat?
    private var isTransitioning = false
    private var isDragging = false
    private var isMoving = false
    private var moveToken = 0
    private var dragStartY: CGFloat = 0
    private var sheet: InAppBrowserSheet? { presentedViewController as? InAppBrowserSheet }

    init(presented: InAppBrowserSheet, presenting: UIViewController?, selected: InAppBrowserDetent, temporaryHeight: Double?, configuration: Configuration) {
        self.selected = selected
        self.temporaryHeight = temporaryHeight
        self.configuration = configuration
        super.init(presentedViewController: presented, presenting: presenting)
    }

    var layout: InAppBrowserSheetLayout { baseLayout.withTemporary(temporaryHeight) }

    private var baseLayout: InAppBrowserSheetLayout {
        guard let window = containerView?.window ?? presentingViewController.viewIfLoaded?.window else {
            return InAppBrowserSheetLayout(collapsed: nil, medium: nil, large: 0)
        }
        return configuration.layout(window, traitCollection)
    }

    /// 選んでいる段が、この画面では全画面の高さになるか。高さの狭い画面（iPhoneの横向き）では、どの段も全画面の高さになる。
    var coversScreenBehind: Bool {
        let layout = layout
        return layout.height(of: selected) >= layout.large
    }

    /// 伏せた段や中くらいの高さの間は、シートの外に触れたものを後ろの画面へ通す。
    var passesTouchesOutsideSheet: Bool { !coversScreenBehind }

    /// 動いている途中は、画面に見えている引ける範囲に触れたものをシートで受ける。ビューの位置はすでに行き先になっていて、ふつうの判定では外れるため。
    func moveGrabTarget(at point: CGPoint, in window: UIWindow) -> UIView? {
        guard isMoving, let sheet, sheet.barGrabArea.superview != nil,
              let visible = presentedView?.layer.presentation()?.frame,
              let container = containerView else { return nil }
        let origin = container.convert(visible.origin, to: window)
        let grab = sheet.barGrabArea.frame.offsetBy(dx: origin.x, dy: origin.y)
        return grab.contains(point) ? sheet.barGrabArea : nil
    }

    /// - Parameter keepingTemporary: 投稿欄のために下げるときのように、あとでスナップ点へ戻すなら`true`にする。
    func select(_ detent: InAppBrowserDetent, animated: Bool, keepingTemporary: Bool = false) {
        selected = detent
        if detent != .temporary, !keepingTemporary { temporaryHeight = nil }
        guard presentedView != nil, !isTransitioning else { return }
        move(to: detent, velocity: 0, animated: animated)
    }

    private func sheetFrame(for detent: InAppBrowserDetent) -> CGRect {
        guard let container = containerView else { return .zero }
        let layout = layout
        let width = min(container.bounds.width, configuration.maximumWidth)
        return CGRect(
            x: (container.bounds.width - width) / 2,
            y: container.bounds.height - CGFloat(layout.height(of: detent)),
            width: width,
            height: CGFloat(layout.large)
        )
    }

    override var frameOfPresentedViewInContainerView: CGRect { sheetFrame(for: selected) }

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        isTransitioning = true
        guard let container = containerView, let view = presentedViewController.viewIfLoaded else { return }
        dimming.backgroundColor = .black
        dimming.alpha = 0
        dimming.isUserInteractionEnabled = false
        dimming.frame = container.bounds
        dimming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.insertSubview(dimming, at: 0)
        view.clipsToBounds = true
        view.layer.cornerCurve = .continuous
        view.layer.cornerRadius = configuration.cornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.addGestureRecognizer(pan)
        sheet?.barGrabArea.addGestureRecognizer(tap)
        (container.window as? ShakeDetectingWindow)?.browserPresentation = self
        lastBaseLayout = baseLayout
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        super.presentationTransitionDidEnd(completed)
        isTransitioning = false
        guard completed else { return }
        settle()
    }

    override func dismissalTransitionWillBegin() {
        super.dismissalTransitionWillBegin()
        isTransitioning = true
        cancelMove()
        presentedViewController.transitionCoordinator?.animate { [dimming] _ in dimming.alpha = 0 }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        isTransitioning = false
    }

    override func containerViewDidLayoutSubviews() {
        super.containerViewDidLayoutSubviews()
        guard !isTransitioning, !isDragging, !isMoving, let view = presentedView else { return }
        let target = sheetFrame(for: selected)
        if view.frame != target { view.frame = target }
        updateDimming(height: CGFloat(layout.height(of: selected)))
        let current = baseLayout
        guard current != lastBaseLayout else { return }
        lastBaseLayout = current
        // 画面の回転などで高さが変わると、作ったときの高さは意味を失うので消す。
        temporaryHeight = nil
        if selected == .temporary { selected = current.medium == nil ? .large : .medium }
        settle()
        onLayoutChange?()
    }

    private func updateDimming(height: CGFloat) {
        let layout = layout
        guard let medium = layout.medium else {
            dimming.alpha = 0
            return
        }
        let range = max(CGFloat(layout.large - medium), 1)
        dimming.alpha = max(0, min(1, (height - CGFloat(medium)) / range)) * configuration.maximumDimAlpha
    }

    /// 今見えている位置で止める。動いている途中につかんだときに、飛ばないようにするため。
    private func cancelMove() {
        moveToken += 1
        guard isMoving, let view = presentedView, let visible = view.layer.presentation()?.frame else {
            isMoving = false
            return
        }
        isMoving = false
        UIView.performStoppingSmoothAnimations { view.frame = visible }
    }

    private func move(to detent: InAppBrowserDetent, velocity: CGFloat, animated: Bool) {
        guard let view = presentedView else { return }
        moveToken += 1
        let token = moveToken
        let target = sheetFrame(for: detent)
        let height = CGFloat(layout.height(of: detent))
        let changes = { [weak self, weak view] in
            view?.frame = target
            self?.updateDimming(height: height)
        }
        let finish = { [weak self] in
            guard let self, moveToken == token else { return }
            isMoving = false
            settle()
        }
        guard animated, configuration.duration > 0 else {
            isMoving = false
            UIView.performStoppingSmoothAnimations(changes)
            finish()
            return
        }
        isMoving = true
        let distance = target.minY - view.frame.minY
        guard velocity != 0, distance != 0 else {
            UIView.animateSmoothly(duration: configuration.duration, changes: changes, completion: finish)
            return
        }
        let unitVelocity = max(-20, min(20, velocity / distance))
        UIView.animate(.interpolatingSpring(duration: configuration.duration, bounce: 0, initialVelocity: unitVelocity), changes: changes, completion: finish)
    }

    /// シートが止まったら、Safariのビューの高さを決める。伏せた段では中くらいの高さのままにして、Safariの下のツールバーをシートの下へはみ出させる。
    private func settle() {
        sheet?.resizeSafari(toHeight: safariSheetHeight)
    }

    var safariSheetHeight: CGFloat {
        let layout = layout
        return CGFloat(max(layout.height(of: selected), selected == .collapsed ? layout.medium ?? 0 : 0))
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let view = presentedView, let container = containerView, layout.detents.count > 1 else { return }
        switch pan.state {
        case .began:
            cancelMove()
            isDragging = true
            dragStartY = view.frame.minY
            sheet?.cancelSafariResize()
            updateDwell(height: container.bounds.height - dragStartY)
        case .changed:
            let y = rubberBanded(dragStartY + pan.translation(in: container).y, in: container)
            view.frame.origin.y = y
            updateDimming(height: container.bounds.height - y)
            updateDwell(height: container.bounds.height - y)
        case .ended, .cancelled, .failed:
            isDragging = false
            endDwell()
            finishDrag(height: container.bounds.height - view.frame.minY, velocity: pan.velocity(in: container).y)
        default:
            break
        }
    }

    /// 指が`snapTolerance`の範囲を出たら待ち直し、とどまったままなら、その高さにスナップ点を作る。
    func updateDwell(height: CGFloat) {
        if let anchor = dwellAnchorHeight, abs(anchor - height) <= configuration.snapTolerance { return }
        dwellAnchorHeight = height
        dwell?.cancel()
        dwell = Task(.withoutRequests) { [weak self, configuration] in
            do {
                try await configuration.clock.sleep(for: configuration.snapDwell)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.makeTemporaryDetent(near: height)
        }
    }

    private func endDwell() {
        dwell?.cancel()
        dwellAnchorHeight = nil
    }

    private func makeTemporaryDetent(near height: CGFloat) {
        guard let new = baseLayout.temporaryHeight(near: Double(height), step: InAppBrowserHeight.step), new != temporaryHeight else { return }
        temporaryHeight = new
        UIImpactFeedbackGenerator(style: .light, view: presentedViewController.view).impactOccurred()
    }

    /// 全画面の高さより上へは、指の動きの一部だけ付いていく。
    private func rubberBanded(_ y: CGFloat, in container: UIView) -> CGFloat {
        let top = container.bounds.height - CGFloat(layout.large)
        return y < top ? top - (top - y) * 0.2 : y
    }

    func finishDrag(height: CGFloat, velocity: CGFloat) {
        switch layout.release(height: Double(height), velocity: Double(-velocity), from: selected) {
        case .dismiss:
            presentedViewController.presentingViewController?.dismiss(animated: true) { [weak self] in
                guard let self else { return }
                delegate?.presentationControllerDidDismiss?(self)
            }
        case .detent(let detent):
            let changed = detent != selected
            selected = detent
            if detent != .temporary { temporaryHeight = nil }
            move(to: detent, velocity: velocity, animated: true)
            // 一時スナップ点は、段が同じでも高さが変わっていることがある。
            if changed || detent == .temporary { onSelectionChange?() }
        }
    }

    @objc private func handleTap() {
        selectNextDetent()
    }

    /// 引ける範囲のタップと、VoiceOverのグラバーの操作。次の段へ順に動かす。
    func selectNextDetent() {
        let detents = layout.detents
        guard detents.count > 1, let index = detents.firstIndex(of: selected) else { return }
        select(detents[(index + 1) % detents.count], animated: true)
        onSelectionChange?()
    }
}

/// シートを下から出す、下へ閉じる遷移。
@MainActor
final class InAppBrowserSheetTransition: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private let duration: TimeInterval

    init(isPresenting: Bool, duration: TimeInterval) {
        self.isPresenting = isPresenting
        self.duration = duration
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        duration
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let controller = transitionContext.viewController(forKey: key), let view = controller.viewIfLoaded else {
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            return
        }
        var offscreen = isPresenting ? transitionContext.finalFrame(for: controller) : view.frame
        offscreen.origin.y = container.bounds.height
        let target = isPresenting ? transitionContext.finalFrame(for: controller) : offscreen
        if isPresenting {
            view.frame = offscreen
            container.addSubview(view)
        }
        UIView.animateSmoothly(duration: transitionContext.isAnimated ? duration : 0) {
            view.frame = target
        } completion: {
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        }
    }
}
