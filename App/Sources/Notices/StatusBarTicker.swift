import os
import SciaCore
import UIKit

/// 届いた通知を、ステータスバーの場所に1件ずつ流す。通知タブを開かなくても、反応が来たことに気づけるようにするため。
///
/// 出している間だけ、アプリの上に重ねたウィンドウでステータスバーを隠し、空いた場所に`StatusBarTickerView`を描く。
/// システムのステータスバーはアプリの画面より上に描かれ、その上には描けないため。
/// 流していない間はウィンドウを隠す。隠さないと、重ねたウィンドウがステータスバーの見た目を決めてしまう。
@MainActor
final class StatusBarTicker {
    /// 流してよいか。通知タブを見ているときや、ビューアのように画面全体を覆っているときは流さない。
    var canShow: () -> Bool = { true }
    /// 押されたとき。
    var onTap: () -> Void = {}

    /// 流す画面のシーン。セッションの画面がウィンドウに載る前に作るため、流すときに尋ねる。
    var scene: () -> UIWindowScene? = { nil }
    /// アプリの画面のいちばん下の画面。ステータスバーを隠している間、安全領域を保つのに使う。
    var rootController: () -> UIViewController? = { nil }
    /// ステータスバーを隠している間、アプリの画面の安全領域の上端に足している高さ。
    private var keptSafeAreaTop: CGFloat = 0
    private let tuning: TuningStore
    private var queue: StatusBarTickerQueue<StatusBarTickerItem>
    private var window: TickerWindow?
    private var shownAt: ContinuousClock.Instant?
    private var advanceTask: Task<Void, Never>?
    private let logger = SciaLog.logger(category: "statusBarTicker")

    init(tuning: TuningStore = AppDependencies.tuning) {
        self.tuning = tuning
        queue = StatusBarTickerQueue(timing: TuningCatalog.statusBarTickerTiming(in: tuning))
    }

    func receive(_ notification: MastodonNotification, verdict: FilterVerdict) {
        guard let item = StatusBarTickerItem(notification, verdict: verdict) else { return }
        receive(item)
    }

    func receive(_ item: StatusBarTickerItem) {
        guard canShow() else { return }
        queue.timing = TuningCatalog.statusBarTickerTiming(in: tuning)
        queue.enqueue(item)
        if shownAt == nil {
            advance()
        } else {
            // 出している間に届いたら、待っている数で、今の1件を出しておく時間を測り直す。
            scheduleAdvance()
        }
    }

    /// 流してよいかが変わったかもしれないとき（タブを切り替えたときなど）に呼ぶ。流してはいけなくなっていたら、待っている通知ごと消す。
    func reevaluate() {
        guard shownAt != nil, !canShow() else { return }
        clear()
    }

    /// 待っている通知を捨て、出しているものを消す。
    func clear() {
        queue.removeAll()
        advanceTask?.cancel()
        advanceTask = nil
        dismiss()
    }

    private func advance() {
        guard canShow(), let next = queue.next() else {
            clear()
            return
        }
        guard let window = prepareWindow() else {
            clear()
            return
        }
        logger.info("show kind=\(next.kind.rawValue, privacy: .public) waiting=\(self.queue.waiting.count, privacy: .public)")
        let wasShowing = shownAt != nil
        shownAt = .now
        window.ticker.animationDuration = tuning.value(of: TuningCatalog.statusBarTickerAnimationDuration)
        if !wasShowing {
            window.isHidden = false
            keepSafeArea(whileHiding: true, window: window)
            window.host.hidesStatusBar = true
            UIView.animate(withDuration: window.ticker.animationDuration * 0.5) {
                window.host.setNeedsStatusBarAppearanceUpdate()
            }
        }
        window.ticker.show(next, animated: true)
        UIAccessibility.post(notification: .announcement, argument: window.ticker.accessibilityText)
        scheduleAdvance()
    }

    private func scheduleAdvance() {
        guard let shownAt else { return }
        advanceTask?.cancel()
        let deadline = shownAt + .seconds(queue.displayDuration)
        advanceTask = Task { [weak self] in
            // 出している間にビューアを開いたときなど、流してはいけなくなったらすぐ消す。画面を出す口は多く、どれにも知らせを足すより、出している間だけ見張るほうが漏れないため。
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: min(.milliseconds(200), deadline - .now))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if !self.canShow() {
                    self.clear()
                    return
                }
            }
            self?.advance()
        }
    }

    /// 切り欠きのない画面（iPhone SE、iPad）では、ステータスバーを隠すと、アプリの画面の安全領域の上端がステータスバーの分だけ縮み、画面全体が上へずれる。
    /// 隠している間は、縮んだ分をアプリの画面の安全領域に足して、画面を動かさない。アイランドとノッチの機種では、ステータスバーを隠しても安全領域は変わらない。
    private func keepSafeArea(whileHiding hiding: Bool, window: TickerWindow) {
        guard let root = rootController() else { return }
        root.additionalSafeAreaInsets.top -= keptSafeAreaTop
        keptSafeAreaTop = 0
        guard hiding, case .none = window.ticker.cutout else { return }
        keptSafeAreaTop = window.windowScene?.statusBarManager?.statusBarFrame.height ?? 0
        root.additionalSafeAreaInsets.top += keptSafeAreaTop
    }

    private func dismiss() {
        guard shownAt != nil, let window else {
            shownAt = nil
            return
        }
        shownAt = nil
        keepSafeArea(whileHiding: false, window: window)
        window.host.hidesStatusBar = false
        window.ticker.hide(animated: true) { [weak self, weak window] in
            // 消している間に次の通知が来て出し直していたら、ウィンドウは隠さない。
            guard let self, let window, self.shownAt == nil else { return }
            window.isHidden = true
        }
        UIView.animate(withDuration: window.ticker.animationDuration) {
            window.host.setNeedsStatusBarAppearanceUpdate()
        }
    }

    #if DEBUG
    private var loopTask: Task<Void, Never>?

    /// 通知を出し続けているか。デバッグメニューの印に使う。
    var isLooping: Bool { loopTask != nil }

    /// デバッグメニューの「ステータスバーの通知を出し続ける」。オンの間、`items`を順に1件ずつ、出る、出ている、消えるを繰り返す。
    /// 前の1件が消え終わってから少し間をおいて次を出し、毎回カプセルが広がるところから見られるようにする。
    func setLooping(_ isOn: Bool, items: [StatusBarTickerItem]) {
        loopTask?.cancel()
        loopTask = nil
        guard isOn, !items.isEmpty else { return }
        loopTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                while let self, !Task.isCancelled, self.shownAt != nil || self.window?.isHidden == false {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .seconds(0.8))
                guard !Task.isCancelled, let self else { return }
                // バックグラウンドでは出さない。実物の通知はストリーミングを止めるので届かないが、見本は止まらずに出そうとするため。
                guard self.scene()?.activationState == .foregroundActive else { continue }
                let item = items[index % items.count]
                index += 1
                self.receive(StatusBarTickerItem(id: "loop-\(index)", kind: item.kind, account: item.account, subject: item.subject))
                // 出し始めて、出ている扱いになるのを待つ。通知タブを見ているなどで出せなかったときも、ここで間をおく。
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
    #endif

    /// 流すウィンドウを用意し、今の画面の形を当てる。ステータスバーのない向きではnil。
    private func prepareWindow() -> TickerWindow? {
        guard let scene = scene(), let reference = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              let cutout = StatusBarCutout.current(in: reference)
        else { return nil }
        if let window {
            window.ticker.setCutout(cutout)
            return window
        }
        let window = TickerWindow(windowScene: scene, cutout: cutout)
        MediaDynamicRangeTraits.follow(window, settings: AppDependencies.settings, { $0.mediaDynamicRange }) { window, range in
            window.traitOverrides.imageDynamicRange = range
        }
        window.ticker.onTap = { [weak self] in
            self?.onTap()
        }
        self.window = window
        return window
    }
}

/// 通知を流すときだけ見せる、アプリの上に重ねるウィンドウ。カプセルの外の指は、下のウィンドウに通す。
private final class TickerWindow: UIWindow {
    let host: TickerHostController
    var ticker: StatusBarTickerView { host.ticker }

    init(windowScene: UIWindowScene, cutout: StatusBarCutout) {
        host = TickerHostController(ticker: StatusBarTickerView(cutout: cutout))
        super.init(windowScene: windowScene)
        windowLevel = .statusBar
        backgroundColor = .clear
        rootViewController = host
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        ticker.tapTarget(at: convert(point, to: ticker))
    }
}

/// 重ねたウィンドウの画面。流している間だけステータスバーを隠す。
private final class TickerHostController: UIViewController {
    let ticker: StatusBarTickerView
    var hidesStatusBar = false

    init(ticker: StatusBarTickerView) {
        self.ticker = ticker
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { hidesStatusBar }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        ticker.frame = view.bounds
        ticker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(ticker)
        self.view = view
    }
}
