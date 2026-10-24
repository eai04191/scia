import SciaCore
import UIKit

/// ウインドウに重ねる、アプリ内通知のチップの列。画面ごとではなくウインドウに1本だけ置き、画面を移ってもその場に残す。
/// 決まりはdocs/notices.mdの「置き場所」にある。
///
/// 列は、前に出ている画面（`NoticeScreen`）が上から使っている分のすぐ下に置く。前の画面は、ウインドウの根の画面から、
/// 入れ物（タブ、ナビゲーション）は前に出ている子へ、重ねて出した画面は列の位置を決める画面（ビューア）へ、たどって決める。
///
/// ウインドウの中では、根の画面のすぐ上に置く。シートやアラートは、その上に重なって列を覆う。ビューアを開いたときだけ、ビューアの上へ出す。
final class NoticeOverlay: UIView {
    let notices: NoticeCenter
    let column = NoticeColumnView()
    private let tuning: TuningStore
    private let sideMargin: CGFloat = 16
    /// 出たままのアプリ内通知。前に出ている画面のものと、アプリ全体のものをまとめる。
    private var persistentNotices = PersistentNotices()
    /// 画面を移る動きに相乗りしている間。スクロールなどで毎フレーム置き直す頼みは、移り終えるまで見送る。
    private var isFollowingTransition = false
    /// 最後に決めた列の上端。指を離したときに、ここへ動かす。
    private var placedTop: CGFloat?
    /// 上へスワイプしてしまった出たままのアプリ内通知と、そのとき持っていた出たままのアプリ内通知のid。
    /// 文言や種類が変わるか、新しいアプリ内通知が出るまで、出さない。進み具合が変わっただけでは出さない。
    private var dismissedPersistent: (notice: Notice, ids: Set<String>)?

    /// 置き直しの動かし方。
    enum Movement {
        /// 呼んだ側のアニメーションに任せる。アニメーションの中でなければ、すぐ置く。毎フレーム置き直すとき（引っぱる、ビューアをスワイプする）に使う。
        case inherited
        /// この時間をかけて動かす。タブの切り替え。
        case animated(TimeInterval)
    }

    init(notices: NoticeCenter, tuning: TuningStore = AppDependencies.tuning) {
        self.notices = notices
        self.tuning = tuning
        super.init(frame: .zero)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        column.onHoldChange = { [weak self] in self?.holdDidChange() }
        column.stack.onDismissPersistent = { [weak self] notice in
            guard let self else { return }
            dismissedPersistent = (notice, Set(persistentNotices.ids))
        }
        addSubview(column)
        notices.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 置く

    /// `window`に列を重ねる。前に重ねていた列は外す。
    @discardableResult
    static func install(in window: UIWindow, center: NoticeCenter, tuning: TuningStore = AppDependencies.tuning) -> NoticeOverlay {
        remove(from: window)
        let overlay = NoticeOverlay(notices: center, tuning: tuning)
        overlay.frame = window.bounds
        window.addSubview(overlay)
        overlay.reauthenticationDidChange()
        overlay.update()
        return overlay
    }

    static func remove(from window: UIWindow) {
        for overlay in window.subviews.compactMap({ $0 as? NoticeOverlay }) {
            overlay.removeFromSuperview()
        }
    }

    /// `window`に重ねている列。
    static func installed(in window: UIWindow?) -> NoticeOverlay? {
        window?.subviews.lazy.compactMap { $0 as? NoticeOverlay }.first
    }

    /// ウインドウの手前へ出す。ビューアを開いたときと、ビューアを閉じる動きを手前の層で描き始めたときに呼ぶ。
    func bringToFront() {
        superview?.bringSubviewToFront(self)
    }

    /// ビューアを閉じ終えたら、根の画面のすぐ上に戻す。ビューアの下に残っているシート（アプリ内のSafariなど）が、また列を覆うようにする。
    /// ほかのビューアを開いていれば、その上に出したままにする。
    func returnBelowPresentations() {
        guard let window, let root = window.rootViewController?.viewIfLoaded else { return }
        var current = window.rootViewController
        while let next = current?.presentedViewController {
            if next is any NoticeScreen, !next.isBeingDismissed { return }
            current = next
        }
        var base: UIView = root
        while let parent = base.superview, parent !== window {
            base = parent
        }
        guard base.superview === window else { return }
        window.insertSubview(self, aboveSubview: base)
    }

    // MARK: 前の画面

    /// 入れ物のうち、前に出ている子。入れ物でなければnil。
    private static func frontChild(of viewController: UIViewController) -> UIViewController? {
        switch viewController {
        case let navigation as UINavigationController: navigation.topViewController
        case let tabs as UITabBarController: tabs.selectedViewController
        case let switchTab as SwitchTabViewController: switchTab.current
        default: nil
        }
    }

    /// 前に出ている画面が伝える置き場所。根の画面から入れ物をたどった画面に、重ねて出した列の位置を決める画面があれば、それを重ねる。
    private func placement() -> NoticePlacement? {
        guard let root = window?.rootViewController else { return nil }
        var base = root
        while let child = Self.frontChild(of: base) {
            base = child
        }
        var placement = (base as? any NoticeScreen)?.noticePlacement(below: 0) ?? NoticePlacement(top: Self.defaultTop(of: base))
        var current = root
        while let next = current.presentedViewController, !next.isBeingDismissed {
            if let screen = next as? any NoticeScreen {
                placement = screen.noticePlacement(below: placement.top)
            }
            current = next
        }
        return placement
    }

    /// 列の位置を決めない画面では、上の安全領域（ナビゲーションバーを含む）のすぐ下に置く。
    static func defaultTop(of viewController: UIViewController) -> CGFloat {
        guard let view = viewController.viewIfLoaded else { return 0 }
        return view.convert(CGPoint(x: 0, y: view.safeAreaInsets.top + 8), to: nil).y
    }

    private func context(for placement: NoticePlacement) -> NoticeContext {
        NoticeContext(viewer: placement.viewer, window: window)
    }

    // MARK: 置き直す

    /// 前に出ている画面か、その画面の様子が変わった。中身を決め直し、列を新しい位置へ動かす。
    func update(_ movement: Movement = .inherited) {
        guard let placement = placement() else { return }
        applyTuning()
        refreshContent(placement)
        column.setChromeHidden(placement.hidesChrome, animated: true)
        column.stack.screenAlpha = placement.screenAlpha
        if case .inherited = movement, isFollowingTransition { return }
        move(toTop: placement.top, movement)
    }

    /// 画面を移る動きに相乗りし、前の画面の位置から次の画面の位置へ、同じ進み方で動かす。スワイプで戻る途中は指に合わせて動き、やめたら戻る。
    /// 動きがなければ、タブを切り替えたときと同じく短く動かす。
    func follow(_ coordinator: (any UIViewControllerTransitionCoordinator)?) {
        let duration = tuning.value(of: TuningCatalog.noticeAnimationDuration)
        guard let coordinator else {
            update(.animated(duration))
            return
        }
        // 動きが始まるまでの間にも、次の画面が並べ直すたびに置き直しを頼んでくる。そこで置くと動きの前に行き先へ跳ぶため、頼んだ時点から見送る。
        isFollowingTransition = true
        let started = coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.moveAlongTransition()
        }, completion: { [weak self] _ in
            guard let self else { return }
            isFollowingTransition = false
            // やめたときは、動きは元の位置へ戻って見えるが、置いた値は次の画面の位置のまま残るため、戻った画面の位置に置き直す。
            update(.inherited)
        })
        if !started {
            isFollowingTransition = false
            update(.animated(duration))
        }
    }

    /// 画面を移る動きの中で、次の画面の位置へ置く。動きの進み方は移り変わりに任せる。
    private func moveAlongTransition() {
        guard let placement = placement() else { return }
        move(toTop: placement.top, .inherited)
    }

    private func columnFrame(top: CGFloat) -> CGRect {
        let insets = window?.safeAreaInsets ?? .zero
        let width = max(bounds.width - insets.left - insets.right - sideMargin * 2, 0)
        return CGRect(x: insets.left + sideMargin, y: top, width: width, height: column.height(forWidth: width))
    }

    private func move(toTop top: CGFloat, _ movement: Movement) {
        placedTop = top
        // 指が触れている間は、押そうとしているチップが逃げないよう動かさない。離したら動かす。
        guard !column.isHeld else { return }
        let frame = columnFrame(top: top)
        guard column.frame != frame else { return }
        switch movement {
        case .inherited:
            setColumnFrame(frame)
        case .animated(let duration):
            // 視差効果を減らす設定では、動かさずに置き直す。
            guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
                setColumnFrame(frame)
                return
            }
            UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.setColumnFrame(frame)
            }
        }
    }

    /// 大きさが変わったら、動きに遅れて文言が切れないよう、中身をすぐ並べ直す。
    private func setColumnFrame(_ frame: CGRect) {
        if column.bounds.size != frame.size {
            UIView.performWithoutAnimation {
                column.bounds.size = frame.size
                column.layoutIfNeeded()
            }
        }
        column.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    private func holdDidChange() {
        if column.isHeld {
            // 動いている途中なら、いま見えている位置で止める。centerは動きの終わりの位置を指しているため、見えている位置を使う。
            let shown = column.layer.presentation()?.position ?? column.center
            column.layer.removeAllAnimations()
            column.center = shown
        } else if let placedTop {
            move(toTop: placedTop, .animated(tuning.value(of: TuningCatalog.noticeAnimationDuration)))
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        update()
    }

    // MARK: 中身

    /// アプリ全体の出たままのアプリ内通知が変わった。チップが出るときは、前の画面のその時の位置に置く。
    func contentDidChange() {
        update()
    }

    func reauthenticationDidChange() {
        column.animationDuration = tuning.value(of: TuningCatalog.noticeAnimationDuration)
        column.setReauthentication(notices.reauthentication, animated: window != nil)
        // 段の出入りで列の高さが変わる。
        if let placedTop, !column.isHeld {
            setColumnFrame(columnFrame(top: placedTop))
        }
    }

    /// 出たままのチップに出す1件を選び直す。中身の決め方は様子が変わるたびに呼び直し、同じ見た目なら描き直さない。
    private func refreshContent(_ placement: NoticePlacement) {
        let context = context(for: placement)
        persistentNotices.set(placement.screenNotice, in: .screen)
        // 決め方を外された出どころも、出していたチップを消すため、画面のもの以外のすべての出どころを決め直す。
        for slot in PersistentNotices.Slot.allCases where slot != .screen {
            persistentNotices.set(notices.persistentNotice(in: slot, context: context), in: slot)
        }
        var notice = persistentNotices.chipNotice(showAll: showAll(from: context))
        if let dismissed = dismissedPersistent {
            // 選ばれなかったものでも、新しい出たままのアプリ内通知が出たら、また出す。
            if let shown = notice, Self.staysDismissed(shown, dismissed: dismissed.notice), Set(persistentNotices.ids).isSubset(of: dismissed.ids) {
                notice = nil
            } else {
                dismissedPersistent = nil
            }
        }
        column.stack.setPersistent(notice, belongsToScreen: persistentNotices.chosenSlot == .screen)
    }

    /// しまったものと同じアプリ内通知で、進み具合のほかは変わっていない。
    private static func staysDismissed(_ notice: Notice, dismissed: Notice) -> Bool {
        notice.id == dismissed.id && notice.kind == dismissed.kind && notice.title == dismissed.title && notice.additionalCount == dismissed.additionalCount
            && (notice.valueIsProgress || notice.value == dismissed.value)
    }

    private func applyTuning() {
        column.animationDuration = tuning.value(of: TuningCatalog.noticeAnimationDuration)
        column.stack.dismissDistance = tuning.value(of: TuningCatalog.noticeDismissDistance)
        column.stack.dismissVelocity = tuning.value(of: TuningCatalog.noticeDismissVelocity)
    }

    private func showAll(from context: NoticeContext) -> (@MainActor () -> Void)? {
        guard let show = notices.showOperationStatus else { return nil }
        return {
            guard let presenter = context.presenter else { return }
            show(presenter)
        }
    }

    /// 数秒で消えるチップを出す。中身は、出す時点の前の画面の様子で一度だけ決める。
    func showTransient(_ content: @MainActor (NoticeContext) -> Notice, duration: TimeInterval, replacing slot: PersistentNotices.Slot?) {
        guard let placement = placement() else { return }
        applyTuning()
        let context = context(for: placement)
        let notice = content(context)
        // 新しいアプリ内通知が出たら、しまった出たままのものもまた出す。
        dismissedPersistent = nil
        // 入れ替える出たままのチップが、このアプリ内通知で消えるなら、その場所で入れ替える。ほかに出たままのものがあれば、そのあとで出し直す。
        var replacingID: String?
        if let slot, let shown = column.stack.persistentNotice, persistentNotices.chosenSlot == slot,
           notices.persistentNotice(in: slot, context: context) == nil {
            replacingID = shown.id
            persistentNotices.set(nil, in: slot)
        }
        column.stack.showTransient(notice, duration: duration, replacingPersistent: replacingID)
        update()
    }

    // MARK: 触れたもの

    /// 列の上だけを受け、ほかは下の画面へ通す。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled else { return nil }
        return column.hitTest(convert(point, to: column), with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hitTest(point, with: event) != nil
    }
}

/// 画面を移るときに、チップの列を前の画面の位置から次の画面の位置へ、移り変わりと同じ進み方で動かす。
@MainActor
final class NoticeNavigationDelegate: NSObject, UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        // 動きがなければ、次の画面が並び終えてから置く。並ぶ前は安全領域が分からないため。
        guard let coordinator = navigationController.transitionCoordinator else { return }
        navigationController.noticeOverlay?.follow(coordinator)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        guard !animated else { return }
        navigationController.noticeOverlay?.follow(nil)
    }
}

extension UIViewController {
    /// この画面のウインドウに重ねているチップの列。画面に載る前はnil。
    var noticeOverlay: NoticeOverlay? {
        NoticeOverlay.installed(in: viewIfLoaded?.window)
    }
}
