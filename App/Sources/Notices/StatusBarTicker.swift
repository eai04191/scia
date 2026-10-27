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
    /// 出している間、ステータスバーを隠すか。Macでは、ステータスバーは描かれず、ナビゲーションバーの上に帯が空いているだけなので隠さない。
    /// 隠すと、安全領域がすぐ縮むのに、補う足し分はアニメーションで遅れて効くため、出すたびに画面が約20pt上へ跳ねてから戻る。
    private let hidesSystemStatusBar = !ProcessInfo.processInfo.isiOSAppOnMac
    private let tuning: TuningStore
    private var queue: StatusBarTickerQueue<StatusBarTickerItem>
    private var window: TickerWindow?
    /// 出し始めてから経った長さ。出していなければnil。
    private var sinceShown: (@Sendable () -> Duration)?
    /// 出している長さと、デバッグで出し続ける間合いを数える時計。
    private let clock: any Clock<Duration>
    private var advanceTask: Task<Void, Never>?
    /// 消し終えてから、ステータスバーを出し直し終えるまでを待つ処理。
    private var statusBarReturnTask: Task<Void, Never>?
    private let logger = SciaLog.logger(category: "statusBarTicker")

    init(tuning: TuningStore = AppDependencies.tuning, clock: any Clock<Duration> = AppDependencies.clock) {
        self.tuning = tuning
        self.clock = clock
        queue = StatusBarTickerQueue(timing: TuningCatalog.statusBarTickerTiming(in: tuning))
    }

    /// 流しているビュー。まだ一度も流していなければnil。
    var tickerView: StatusBarTickerView? { window?.ticker }
    /// 重ねたウィンドウがステータスバーを隠しているか。
    var isHidingStatusBar: Bool { window?.host.hidesStatusBar ?? false }

    func receive(_ notification: MastodonNotification, verdict: FilterVerdict) {
        guard let item = StatusBarTickerItem(notification, verdict: verdict) else { return }
        receive(item)
    }

    func receive(_ item: StatusBarTickerItem) {
        guard canShowNow() else { return }
        queue.timing = TuningCatalog.statusBarTickerTiming(in: tuning)
        queue.enqueue(item)
        if sinceShown == nil {
            // ステータスバーを出し直している間は、出し終えてから出す。
            if statusBarReturnTask == nil {
                advance()
            }
        } else {
            // 出している間に届いたら、待っている数で、今の1件を出しておく時間を測り直す。
            scheduleAdvance()
        }
    }

    /// 流してよいかが変わったかもしれないとき（タブを切り替えたときなど）に呼ぶ。流してはいけなくなっていたら、待っている通知ごと消す。
    func reevaluate() {
        guard sinceShown != nil, !canShowNow() else { return }
        clear()
    }

    /// アプリの画面が流してよい状態で、今の向きにステータスバーがあるか。
    /// 出している途中に横向きにしたとき、縦向きの切り欠きの形のまま画面の上を覆わないよう、出している間も向きを確かめる。
    private func canShowNow() -> Bool {
        canShow() && currentCutout() != nil
    }

    /// 今の画面の切り欠きの形。ステータスバーのない向きではnil。
    private func currentCutout() -> StatusBarCutout? {
        // iPadとMacでは、帯をステータスバーの高さで測るが、iPadでは出している間は自分でステータスバーを隠していて高さが0になるため、出し始めに測った形を使う。
        // 出している間にiPadのウィンドウを縮めても、待っている通知を流し終えるまでは同じ形で出す。次に出し始めるときに測り直す。
        // 消したあとも、縮め終えるまではステータスバーを隠したままなので、同じく出し始めに測った形を使う。
        if sinceShown != nil || window?.host.hidesStatusBar == true, let window, window.traitCollection.userInterfaceIdiom != .phone {
            return window.ticker.cutout
        }
        guard let scene = scene(), let reference = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return nil }
        return StatusBarCutout.current(in: reference)
    }

    /// 待っている通知を捨て、出しているものを消す。
    func clear() {
        queue.removeAll()
        advanceTask?.cancel()
        advanceTask = nil
        dismiss()
    }

    private func advance() {
        guard canShowNow(), let next = queue.next() else {
            clear()
            return
        }
        guard let window = prepareWindow() else {
            clear()
            return
        }
        logger.info("show kind=\(next.kind.rawValue, privacy: .public) waiting=\(self.queue.waiting.count, privacy: .public)")
        let wasShowing = sinceShown != nil
        sinceShown = stopwatch(on: clock)
        window.ticker.animationDuration = tuning.value(of: TuningCatalog.statusBarTickerAnimationDuration)
        if !wasShowing {
            window.isHidden = false
        }
        // 縮めている途中に届いたときは、ステータスバーを隠したままなので、隠し直さず、安全領域の補いもそのまま使う。
        // 隠している間はステータスバーの高さが0になり、補い直すと補いが消えて画面が上へずれるため。
        if !window.host.hidesStatusBar, hidesSystemStatusBar {
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
        guard let sinceShown else { return }
        advanceTask?.cancel()
        let duration = Duration.seconds(queue.displayDuration)
        let clock = clock
        advanceTask = Task { [weak self] in
            // 出している間にビューアを開いたときなど、流してはいけなくなったらすぐ消す。画面を出す口は多く、どれにも知らせを足すより、出している間だけ見張るほうが漏れないため。
            // 長押しの拡大表示で読んでいる間は、時間が過ぎても進めず、離すのを待つ。
            while true {
                let remaining = duration - sinceShown()
                let isHeld = self?.window?.ticker.isHeldForLargeContent ?? false
                if remaining <= .zero, !isHeld { break }
                try? await clock.sleep(for: remaining > .zero ? min(.milliseconds(200), remaining) : .milliseconds(200))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if !self.canShowNow() {
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
        guard sinceShown != nil, let window else {
            sinceShown = nil
            return
        }
        sinceShown = nil
        window.ticker.hide(animated: true) { [weak self, weak window] in
            // 消している間に次の通知が来て出し直していたら、ステータスバーは隠したまま、ウィンドウも隠さない。
            guard let self, let window, self.sinceShown == nil else { return }
            self.restoreStatusBar(in: window)
        }
    }

    /// 消し終えてから、ステータスバーを出し直し、出し終えたらウィンドウを隠す。出し終えるまでに届いた通知は、出し終えてから出す。
    /// ステータスバーを出し直している途中に隠し直すと、システムは途中の濃さからではなく、1コマで濃く出してから薄くし、薄くなるまでカプセルの上に重なって描く。
    /// 縮めている途中から出し直すと、縮めている途中に次の通知が届いたときにそうなるため、縮め終えるまでステータスバーは隠したままにする。
    private func restoreStatusBar(in window: TickerWindow) {
        guard hidesSystemStatusBar else {
            window.isHidden = true
            return
        }
        keepSafeArea(whileHiding: false, window: window)
        window.host.hidesStatusBar = false
        let duration = window.ticker.animationDuration
        UIView.animate(withDuration: duration) {
            window.host.setNeedsStatusBarAppearanceUpdate()
        }
        let clock = clock
        statusBarReturnTask = Task { [weak self, weak window] in
            try? await clock.sleep(for: .seconds(duration))
            guard let self else { return }
            self.statusBarReturnTask = nil
            if !self.queue.waiting.isEmpty, self.canShowNow() {
                self.advance()
            } else {
                // 待っている間に流せなくなったら（ビューアを開いたときなど）、待っている通知を捨て、ウィンドウを隠す。
                // 残すと、重ねたウィンドウがステータスバーの見た目を決めてしまう。
                self.queue.removeAll()
                window?.isHidden = true
            }
        }
    }

    #if DEBUG
    private var loopTask: Task<Void, Never>?

    /// 通知を出し続けているか。デバッグメニューのチェックマークに使う。
    var isLooping: Bool { loopTask != nil }

    /// デバッグメニューの「ステータスバーの通知を出し続ける」。オンの間、`items`を順に1件ずつ、出る、出ている、消えるを繰り返す。
    /// 前の1件が消え終わってから少し間をおいて次を出し、毎回カプセルが広がるところから見られるようにする。
    func setLooping(_ isOn: Bool, items: [StatusBarTickerItem]) {
        loopTask?.cancel()
        loopTask = nil
        guard isOn, !items.isEmpty else { return }
        let clock = clock
        loopTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                while let self, !Task.isCancelled, self.sinceShown != nil || self.window?.isHidden == false {
                    try? await clock.sleep(for: .milliseconds(50))
                }
                try? await clock.sleep(for: .seconds(0.8))
                guard !Task.isCancelled, let self else { return }
                // バックグラウンドでは出さない。実物の通知はストリーミングを止めるので届かないが、見本は止まらずに出そうとするため。
                guard self.scene()?.activationState == .foregroundActive else { continue }
                let item = items[index % items.count]
                index += 1
                self.receive(StatusBarTickerItem(id: "loop-\(index)", kind: item.kind, account: item.account, subject: item.subject))
                // 出し始めて、出ている扱いになるのを待つ。通知タブを見ているなどで出せなかったときも、ここで間をおく。
                try? await clock.sleep(for: .milliseconds(200))
            }
        }
    }
    #endif

    /// 流すウィンドウを用意し、今の画面の形を当てる。ステータスバーのない向きではnil。
    private func prepareWindow() -> TickerWindow? {
        guard let scene = scene(), let cutout = currentCutout() else { return nil }
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
        // 見張りの間隔を待たず、回し始めたところで消す。
        window.host.onVerticalSizeClassChange = { [weak self] in
            self?.reevaluate()
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
    /// 縦と横を回して、ステータスバーのある向きかが変わったとき。
    var onVerticalSizeClassChange: () -> Void = {}

    init(ticker: StatusBarTickerView) {
        self.ticker = ticker
        super.init(nibName: nil, bundle: nil)
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in
            self.onVerticalSizeClassChange()
        }
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
