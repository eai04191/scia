import os
import SafariServices
import SciaCore
import UIKit

/// 本文のリンクを、アプリ内のSafariで開く。中くらいの高さのシートで出し、後ろを暗くせず、上に見えるタイムラインを触れるままにする。
/// アプリは手前にいたままなので、読んでいる間もストリーミングが流れ続ける。
///
/// シートの高さは、伏せた高さ（URLのバーだけ見える）、中くらいの高さ、全画面の3段。投稿欄で書いている間は伏せた高さまで下げ、書き終えたら戻す。
/// シートは`InAppBrowserPresentationController`で動かし、高さを変えるのは上端の帯とSafariのバーの真ん中を引いたときだけにする。ページのスワイプでシートが下がらないようにするため。
@MainActor
final class InAppBrowser: NSObject, @MainActor SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    /// シートが画面の下から覆っている高さが変わったときに呼ぶ。閉じたら0を渡す。タイムラインの下に、シートより上へ出せるだけの余白を取るために使う。
    var onObscuredHeightChange: ((CGFloat) -> Void)?
    /// シートを手で伏せた高さまで下げて、後ろの画面をシートの上に縮めるときに、シートが画面の下から占める高さを渡す。縮めないときは0を渡す。
    /// `animated`がfalseなら、動かさずに変える。
    var onDockedHeightChange: ((_ height: CGFloat, _ animated: Bool) -> Void)?
    /// シートを全画面に広げてタイムラインを覆ったか、覆うのをやめたときに呼ぶ。覆っている間は、タイムラインの投稿を見たと報告させない。
    var onCoverageChange: ((Bool) -> Void)?
    /// シートを出したか、閉じたときに呼ぶ。中身を差し替えるときは呼ばない。
    var onPresenceChange: ((Bool) -> Void)?

    private let tuning: TuningStore
    private let settings: AppSettings
    private let clock: any Clock<Duration>
    private weak var current: InAppBrowserSheet?
    /// 投稿欄で書き始めて伏せる前の高さ。書き終えたらここへ戻す。書いている間に手で高さを変えたら、手で選んだ高さを尊重して戻さない。
    private var detentBeforeCompose: InAppBrowserDetent?
    /// 伏せた高さで出して、開く高さまで広げ終えるまでの間。この間は伏せた段にいても、後ろの画面を縮めない。
    private var isGrowingFromCollapsed = false
    private let logger = SciaLog.logger(category: "browser")

    init(tuning: TuningStore = AppDependencies.tuning, settings: AppSettings, clock: any Clock<Duration> = AppDependencies.clock, frameSource: any FrameSource = DisplayLinkFrameSource.shared) {
        self.tuning = tuning
        self.settings = settings
        self.clock = clock
        self.frameSource = frameSource
    }

    /// シートを出している。中身を差し替える途中も含む。
    var isPresented: Bool { current != nil }

    private var presentation: InAppBrowserPresentationController? {
        guard let current, !current.isBeingDismissed else { return nil }
        return current.sheetPresentation
    }

    /// `url`はhttpかhttpsに限る。ほかのスキームを渡すとSFSafariViewControllerが例外で落ちるため、呼び出し側で`LinkBrowser`に振り分けさせる。
    /// シートを出している間に別のリンクが押されたら、高さを保ったまま中身を差し替える。
    /// 重ねた画面のどれかを閉じている途中なら、閉じ終えてから開く。
    func open(_ url: URL, from root: UIViewController) {
        root.afterOngoingDismissal { [weak self] in self?.openAfterDismissal(url, from: root) }
    }

    private func openAfterDismissal(_ url: URL, from root: UIViewController) {
        guard root.viewIfLoaded?.window != nil else {
            // 窓にない画面からはシートを出せないので、開かない。
            logger.error("in-app browser open ignored without window")
            return
        }
        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        let browserSheet = makeSheet(safari: safari)
        if let current, let presenter = current.presentingViewController, !current.isBeingDismissed {
            browserSheet.initialDetent = current.sheetPresentation?.selected ?? openingDetent
            browserSheet.initialTemporaryHeight = current.sheetPresentation?.temporaryHeight
            self.current = browserSheet
            logger.info("in-app browser replace")
            // 同じ位置に同じ大きさで出し直すので、動かさずに入れ替える。
            // 上に重ねた画面（投稿欄のシートなど）があれば一緒に閉じ、閉じたことを知らせる。`current`の`dismiss`では、上の画面だけが閉じてシートが残る。
            presenter.dismissPresentedScreens(animated: false) {
                presenter.present(browserSheet, animated: false)
                browserSheet.presentSafari()
            }
            return
        }
        current = browserSheet
        detentBeforeCompose = nil
        let grows = tuning.value(of: TuningCatalog.inAppBrowserGrowsFromCollapsed)
        browserSheet.initialDetent = grows ? .collapsed : openingDetent
        isGrowingFromCollapsed = grows
        logger.info("in-app browser open grows=\(grows, privacy: .public)")
        onPresenceChange?(true)
        let opening = openingDetent
        root.frontmostPresented.present(browserSheet, animated: true) { [weak self, weak browserSheet] in
            guard let self, let browserSheet, self.current === browserSheet, let presentation = browserSheet.sheetPresentation else { return }
            guard grows else {
                // 全画面で開いたときに、タイムラインを覆ったことを知らせる。
                self.selectionDidChange(presentation)
                return
            }
            self.isGrowingFromCollapsed = false
            guard presentation.selected == .collapsed else {
                self.reportObscuredHeight(of: presentation)
                return
            }
            self.select(opening, on: presentation)
        }
        browserSheet.presentSafari()
    }

    /// 全画面で開く。SFSafariViewControllerを標準の出し方で出し、右から入り、左端から右へのスワイプで閉じるようにする。
    /// 読み込みの間は、シートを手で伏せた高さまで下げたときと同じ見え方で待ち、読み込み終えたら全画面に広げる。伏せた高さのない画面（iPhoneの横向き、iPad）では、すぐ全画面で出す。
    /// 全画面に広げたあとは、Safariのバーの上の引ける範囲（URLが出ているところ）をタップすると、同じ伏せた見え方に戻す（`collapse`）。伏せたシートを引き上げると、また全画面に広げる。
    /// `url`の条件と、閉じている途中の画面を待つのは`open`と同じ。
    func openFullScreen(_ url: URL, from root: UIViewController) {
        root.afterOngoingDismissal { [weak self] in self?.openFullScreenAfterDismissal(url, from: root) }
    }

    private func openFullScreenAfterDismissal(_ url: URL, from root: UIViewController) {
        guard let window = root.viewIfLoaded?.window, let scene = window.windowScene else {
            logger.error("in-app browser full screen open ignored without window")
            return
        }
        dropFullScreenOverlay()
        // 出しているシート（伏せたシートを含む）は、閉じ終えてから次を出す。閉じ終える前に出すと、UIKitが出すのを断る。
        // `root`が閉じるシートやその上の画面のこともあるので、閉じ終えたら、残った側の画面から出す。
        if let current, let presenter = current.presentingViewController {
            presenter.dismissPresentedScreens(animated: false) { [weak self] in
                guard let self else { return }
                if self.current === current { self.didClose(current) }
                self.presentFullScreen(url, from: presenter, in: window, scene: scene)
            }
            return
        }
        presentFullScreen(url, from: root, in: window, scene: scene)
    }

    private func presentFullScreen(_ url: URL, from root: UIViewController, in window: UIWindow, scene: UIWindowScene) {
        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        let overlay = InAppBrowserOverlayWindow(windowScene: scene, behind: { [weak window] in window }, barGrab: barGrab, frameSource: frameSource)
        // 重ねたウインドウを隠す経路（`closeFullScreen`）のほかに、Safariが閉じたことを知る。
        safari.presentationController?.delegate = self
        let session = FullScreenSession(safari: safari, window: overlay, appWindow: window)
        fullScreen = session
        overlay.onCollapsedDismissalBegin = { [weak self, weak session] in
            // ×で閉じ始めたら、閉じたという知らせ（`safariViewControllerDidFinish`）を待たずに閉じる。知らせはSafariの閉じる動きの終わり近くに届くため。
            guard let self, let session else { return }
            self.didCloseFullScreen(session)
        }
        // Safariのバーの上の引ける範囲は、伏せている間はシートの引ける範囲として動き、全画面に広げている間はタップで伏せる。
        overlay.onBarGrabTap = { [weak self, weak session] in
            guard let self, let session else { return }
            if let presentation = session.collapsedSheet?.sheetPresentation {
                presentation.selectNextDetent()
            } else {
                self.collapse(session)
            }
        }
        overlay.canCollapse = { [weak self, weak overlay] in
            guard let self, let overlay else { return false }
            return self.collapsesWhileLoading(in: overlay)
        }
        overlay.onBarGrabPan = { [weak session] state, translation, velocity in
            session?.collapsedSheet?.sheetPresentation?.drag(state, translation: translation, velocity: velocity)
        }
        guard collapsesWhileLoading(in: window) else {
            logger.info("in-app browser open full screen")
            session.awaitsFirstExpansion = false
            overlay.isHidden = false
            onCoverageChange?(true)
            overlay.presenter?.present(safari, animated: true)
            return
        }
        logger.info("in-app browser open full screen from collapsed sheet")
        let browserSheet = makeSheet(safari: nil)
        browserSheet.initialDetent = .collapsed
        current = browserSheet
        session.collapsedSheet = browserSheet
        detentBeforeCompose = nil
        isGrowingFromCollapsed = false
        onPresenceChange?(true)
        root.frontmostPresented.present(browserSheet, animated: true)
        // 手で伏せた高さまで下げたときと同じく、後ろの画面をシートの上に縮める。シートが動き始めるのと同じコマで縮め始めるよう、シートを出す動きに載せる。
        // `present`を呼んだ時点で縮めると、シートが動き始めるより先に縮み、空いたところにタイムラインの端が見える（iOS 27のシミュレーターで録って確かめた）。
        let dock = { [weak self, weak browserSheet] in
            guard let self, let presentation = browserSheet?.sheetPresentation else { return }
            self.selectionDidChange(presentation)
        }
        if let coordinator = browserSheet.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in dock() })
        } else {
            dock()
        }
        browserSheet.presentSafari()
        // シートが上がってくる間も、Safariのバーがシートと一緒に動くよう、出し始めから重ねる。
        overlay.alpha = 0
        overlay.isHidden = false
        overlay.presenter?.present(safari, animated: false)
        startFollowing(session)
        _ = follow(session)
    }

    /// 伏せている間、毎コマ重ねたウインドウをシートの位置に合わせ始める。もう合わせていれば何もしない。
    /// シートが止まったら止め（`follow`）、シートが動き出すとき（引く、段を変える、上に画面を出す、画面の大きさが変わる）にまた始める（`collapsedSheetMayMove`）。
    private func startFollowing(_ session: FullScreenSession) {
        guard session.follower?.isRunning != true else { return }
        session.stillFrames = 0
        // 合わせている間はセッションを持ち続ける（閉じる途中は、ブラウザーがセッションを手放したあとも、下がるシートに付いていくため）。
        // 止めるときにセッションからの参照を外し、持ち合いを解く。外さないと、ブラウザーがなくなったあと（アカウントを切り替えたなど）、セッションと重ねたウインドウが残る。
        let follower = FrameTicker(source: frameSource) { [weak self, session] _ in
            guard let self else {
                session.follower = nil
                return false
            }
            return self.follow(session)
        }
        session.follower = follower
        follower.start()
    }

    /// 伏せたシートが動き出すかもしれないときに呼ぶ。止めていた、毎コマ合わせる処理を始め直す。
    private func collapsedSheetMayMove(_ sheet: InAppBrowserSheet?) {
        guard let session = fullScreen, let sheet, session.collapsedSheet === sheet, session.window.isCollapsed, !session.window.isHidden else { return }
        startFollowing(session)
    }

    /// 全画面に広げたSafariを、読み込みの間と同じ伏せた見え方に戻す。伏せたシートを動かさずに出し、その上の位置までSafariを縮める。
    /// 伏せた高さのない画面（iPhoneの横向き、iPad）や、アプリのウインドウにほかのシートを出している間は戻さない。
    private func collapse(_ session: FullScreenSession) {
        guard fullScreen === session, session.collapsedSheet == nil, current == nil,
              let appWindow = session.appWindow, collapsesWhileLoading(in: appWindow),
              let root = appWindow.rootViewController else { return }
        logger.info("in-app browser full screen collapse \(session.window.geometryLog, privacy: .public)")
        let browserSheet = makeSheet(safari: nil)
        browserSheet.initialDetent = .collapsed
        current = browserSheet
        session.collapsedSheet = browserSheet
        detentBeforeCompose = nil
        isGrowingFromCollapsed = false
        onPresenceChange?(true)
        // 全画面のSafariの裏で出すので、動かさない。Safariが縮むのに合わせて、後ろの画面を縮める。
        root.frontmostPresented.present(browserSheet, animated: false) { [weak self, weak browserSheet, weak session] in
            guard let self, let browserSheet, let session, session.collapsedSheet === browserSheet, let presentation = browserSheet.sheetPresentation else { return }
            browserSheet.presentSafari()
            browserSheet.view.layoutIfNeeded()
            guard let top = browserSheet.safariTopOnScreen, let shape = browserSheet.shapeOnScreen else { return }
            self.onCoverageChange?(false)
            self.selectionDidChange(presentation)
            session.window.collapse(safariTop: top, sheet: shape) { [weak self, weak session] in
                // 縮める途中に引き上げて、もう広げ始めていたら、合わせ続けない。
                guard let self, let session, self.fullScreen === session, session.collapsedSheet === browserSheet, session.window.isCollapsed else { return }
                self.logger.info("in-app browser full screen collapsed \(session.window.geometryLog, privacy: .public)")
                self.startFollowing(session)
            }
        }
    }

    /// 全画面で開いたSafariと、それを載せた重ねたウインドウ。伏せている間（読み込みの間と、バーの上の引ける範囲をタップして伏せた間）は、伏せたシートに重ねる。
    private final class FullScreenSession {
        let safari: SFSafariViewController
        let window: InAppBrowserOverlayWindow
        /// 伏せたシートを出すアプリのウインドウ。
        weak var appWindow: UIWindow?
        /// 伏せている間に重ねている、Safariを持たない伏せたシート。全画面に広げている間はnil。
        weak var collapsedSheet: InAppBrowserSheet?
        /// 伏せている間、毎コマ重ねたウインドウをシートの位置に合わせる。シートが止まっている間は止める。
        var follower: FrameTicker?
        /// 合わせた位置と、同じ位置のまま続いたコマの数。
        var lastPlacement: (top: CGFloat, frame: CGRect)?
        var stillFrames = 0
        /// 読み込み終えたが、シートの上に別の画面を重ねていたので、広げるのを待っている。
        var expandsWhenUncovered = false
        /// まだ一度も広げていない。読み込み終えたときに広げるのはこの間だけにし、広げたあとに手で伏せた形を、あとから届いた読み込みの終わりで広げない。
        var awaitsFirstExpansion = true

        init(safari: SFSafariViewController, window: InAppBrowserOverlayWindow, appWindow: UIWindow) {
            self.safari = safari
            self.window = window
            self.appWindow = appWindow
        }
    }

    /// 全画面で出しているSafari（`openFullScreen`）。閉じ始めたらnil。
    private var fullScreen: FullScreenSession?
    private let frameSource: any FrameSource

    /// 読み込みの間、伏せたシートで待つか。iPhoneの縦向きで、シートが画面の幅いっぱいのときだけにする。
    /// iPhoneの横向きには伏せた高さがない。iPadでは、狭いウインドウでも伏せたシートの上にSafariのバーが出なかった（iOS 27のシミュレーター）。
    /// 重ねたSafariは画面の幅で描かれるので、シートが画面より狭いと（チューニングの最大幅）、シートの形で切り抜くと左右のボタンが欠ける。
    private func collapsesWhileLoading(in window: UIWindow) -> Bool {
        let traits = window.traitCollection
        guard traits.userInterfaceIdiom == .phone, traits.horizontalSizeClass == .compact, traits.verticalSizeClass == .regular else { return false }
        guard CGFloat(tuning.value(of: TuningCatalog.inAppBrowserSheetMaximumWidth)) >= window.bounds.width else { return false }
        return sheetLayout(in: window, traits: traits).collapsed != nil
    }

    /// 重ねたウインドウを、伏せたシートのSafariを出す場所に合わせる。シートの上に別の画面を重ねている間は、Safariのバーがその画面の上に出ないよう、見えなくする。
    /// シートがなくなったら、続けないのでfalseを返す。
    private func follow(_ session: FullScreenSession) -> Bool {
        guard let sheet = session.collapsedSheet, !session.window.isHidden else {
            session.follower = nil
            return false
        }
        guard let top = sheet.safariTopOnScreen, let shape = sheet.shapeOnScreen, !Self.isCovered(sheet, shape: shape) else {
            session.window.alpha = 0
            return true
        }
        // 広げるのは、重ねた画面（Safariの範囲にかからないメニューも含む）がなくなってから（`expand`）。それまでは合わせ続ける。
        if session.expandsWhenUncovered, sheet.presentedViewController == nil {
            session.follower = nil
            expand(session)
            return false
        }
        let placed = session.window.placeCollapsed(safariTop: top, sheet: shape)
        session.window.alpha = placed ? 1 : 0
        // シートが止まり、上に画面もないまま同じ位置が続いたら、合わせるのをやめる。動き続けると、止まっている間も80〜120Hzを頼み続けるため。
        let placement = (top: top, frame: shape.frame)
        let isStill = placed && sheet.presentedViewController == nil && (sheet.view.layer.animationKeys() ?? []).isEmpty
            && session.lastPlacement.map { $0.top == placement.top && $0.frame == placement.frame } == true
        session.lastPlacement = placement
        session.stillFrames = isStill ? session.stillFrames + 1 : 0
        guard session.stillFrames < Self.stillFramesBeforeStopping else {
            session.follower = nil
            return false
        }
        return true
    }

    /// 伏せたシートが止まってから、合わせるのをやめるまでのコマの数。
    private static let stillFramesBeforeStopping = 2

    /// 伏せたシートの上に重ねた画面が、Safariの見えている範囲（`shape`）にかかるか。かかるなら、Safariのバーがその画面の上に出ないよう隠す。
    /// メニューも、シートの上に重ねた画面として出る（iOSの`_UIContextMenuActionsOnlyViewController`）が、その画面のビューはメニューの中身を持たない小さなビューで、Safariの範囲にかからないので隠さない。
    /// 隠すと、Safariを持たない伏せたシートだけが残って見える。アラートは画面全体を暗くするので、範囲にかからなくても隠す。
    private static func isCovered(_ sheet: InAppBrowserSheet, shape: InAppBrowserSheetShape) -> Bool {
        guard let presented = sheet.presentedViewController else { return false }
        if presented is UIAlertController { return true }
        guard let view = presented.viewIfLoaded, let window = view.window else { return true }
        let frame = window.convert(view.convert(view.bounds, to: window), to: nil)
        return frame.intersects(shape.frame)
    }

    /// 伏せたシートで待つのをやめ、全画面に広げる。広げ終えたら、裏に隠れたシートを片付ける。
    /// シートの上に別の画面を重ねている間は広げず、その画面が閉じてから広げる（`follow`）。重ねたまま広げると、伏せたシートを片付けるときに、上の画面まで閉じてしまう。
    private func expand(_ session: FullScreenSession) {
        guard fullScreen === session, let sheet = session.collapsedSheet else { return }
        // 広げている途中なら、始め直さない。始め直すと、広げ終える前に伏せたシートを片付けてしまう。
        guard !session.window.isExpanding else { return }
        guard sheet.presentedViewController == nil else {
            session.expandsWhenUncovered = true
            // 上の画面が閉じたら広げるのは、毎コマ合わせる処理（`follow`）。止めていたら始め直す。メニューのように、シートを通らずに出る画面では、出したときに始め直せないため。
            startFollowing(session)
            return
        }
        logger.info("in-app browser full screen expand \(session.window.geometryLog, privacy: .public)")
        session.expandsWhenUncovered = false
        session.awaitsFirstExpansion = false
        session.follower?.stop()
        session.follower = nil
        session.window.alpha = 1
        onCoverageChange?(true)
        session.window.expand { [weak self, weak sheet] in
            self?.logger.info("in-app browser full screen expanded \(session.window.geometryLog, privacy: .public)")
            // 広げ終えるまでに、別の伏せたシートに替わっていたら、そちらは片付けない。
            guard let self, let sheet, session.collapsedSheet === sheet else { return }
            // 広げる途中にシートの上に画面を重ねたら（行き先を開いたなど）、その画面を閉じない。読み込みの間に重ねたときと同じく、Safariを隠し、その画面を閉じてから広げる（`follow`）。
            guard sheet.presentedViewController == nil else {
                session.expandsWhenUncovered = true
                self.onCoverageChange?(false)
                self.startFollowing(session)
                return
            }
            session.collapsedSheet = nil
            sheet.presentingViewController?.dismiss(animated: false)
            self.didClose(sheet, coversScreenBehind: self.fullScreen === session)
        }
    }

    /// 全画面に広げたSafariを出しているか。広げたあとはアプリのウインドウに何も重ねていないので、重ねた画面があるかだけでは分からない。
    var showsFullScreen: Bool { fullScreen != nil && fullScreen?.collapsedSheet == nil }

    /// 全画面に広げたSafariを、動かさずに閉じる。重ねた画面をまとめて閉じるとき（行き先を開く、共有から戻る）に呼ぶ。
    /// 重ねたウインドウは、`dismissPresentedScreens`が辿るアプリのウインドウの外にあるため、別に閉じる。
    /// 読み込みの間は何もしない。伏せたシートはアプリのウインドウにあり、まとめて閉じる経路が書きかけの画面を守りながら閉じ、閉じたら重ねたSafariも閉じる（`presentationControllerDidDismiss`）。
    func closeFullScreen() {
        guard showsFullScreen else { return }
        logger.info("in-app browser full screen close")
        dropFullScreenOverlay()
        onCoverageChange?(presentation?.coversScreenBehind ?? false)
    }

    /// アプリのセッションを終えるとき（アカウントを切り替えたときなど）に呼ぶ。全画面で開いたSafariを載せた重ねたウインドウは、アプリのウインドウの外にあり、画面を作り直しても残るので閉じる。
    func stop() {
        dropFullScreenOverlay()
    }

    /// 重ねたウインドウを、動かさずに閉じる。伏せたシートは閉じない。
    private func dropFullScreenOverlay() {
        guard let session = fullScreen else { return }
        fullScreen = nil
        session.follower?.stop()
        session.follower = nil
        session.window.presenter?.dismiss(animated: false)
        session.window.isHidden = true
    }

    func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
        logger.info("in-app browser initial load completed ok=\(didLoadSuccessfully, privacy: .public)")
        // 読み込めなかったときも、Safariが出す失敗のページを見せるために広げる。
        guard let session = fullScreen, session.safari === controller, session.awaitsFirstExpansion else { return }
        expand(session)
    }

    /// Safariのバーの上に重ねる、シートを引ける範囲。シートと、全画面で開くSafariを載せた重ねたウインドウで同じものを使う。
    private var barGrab: InAppBrowserBarGrab {
        InAppBrowserBarGrab(
            height: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserBarGrabHeight)),
            inset: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserBarGrabInset)),
            isVisible: tuning.value(of: TuningCatalog.inAppBrowserShowsBarGrabArea),
            handleHeight: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserHandleHeight)),
            safariTopInset: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserSafariTopInset))
        )
    }

    private func makeSheet(safari: SFSafariViewController?) -> InAppBrowserSheet {
        let configuration = InAppBrowserPresentationController.Configuration(
            cornerRadius: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserDockCornerRadius)),
            duration: { [tuning] in tuning.value(of: TuningCatalog.inAppBrowserDockDuration) },
            maximumWidth: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserSheetMaximumWidth)),
            maximumDimAlpha: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserSheetDimAlpha)),
            snapDwell: .seconds(tuning.value(of: TuningCatalog.inAppBrowserSnapDwell)),
            snapTolerance: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserSnapTolerance)),
            clock: clock,
            layout: { [weak self] window, traits in
                self?.sheetLayout(in: window, traits: traits) ?? InAppBrowserSheetLayout(collapsed: nil, medium: nil, large: window.bounds.height)
            }
        )
        let browserSheet = InAppBrowserSheet(
            safari: safari,
            barGrab: barGrab,
            safariResizeDelay: .seconds(tuning.value(of: TuningCatalog.inAppBrowserSafariResizeDelay)),
            clock: clock,
            configuration: configuration
        )
        browserSheet.presentationDelegate = self
        browserSheet.onMayMove = { [weak self, weak browserSheet] in self?.collapsedSheetMayMove(browserSheet) }
        browserSheet.onPresentationCreated = { [weak self] presentation in
            presentation.onSelectionChange = { [weak self, weak presentation] in
                guard let self, let presentation else { return }
                self.userDidChangeSelection(presentation)
            }
            presentation.onLayoutChange = { [weak self, weak presentation] in
                guard let self, let presentation else { return }
                self.selectionDidChange(presentation)
            }
            presentation.onMove = { [weak self, weak presentation] in
                self?.collapsedSheetMayMove(presentation?.presentedViewController as? InAppBrowserSheet)
            }
        }
        return browserSheet
    }

    /// 投稿欄で書き始めたときに呼ぶ。シートは投稿欄より手前に出るため、伏せた高さまで下げてキーボードの裏へ逃がす。
    func lowerForCompose() {
        guard let presentation, presentation.selected != .collapsed else { return }
        detentBeforeCompose = presentation.selected
        logger.info("in-app browser lower for compose from=\(presentation.selected.rawValue, privacy: .public)")
        presentation.select(.collapsed, animated: true, keepingTemporary: true)
        selectionDidChange(presentation)
    }

    /// 後ろの画面に別の画面を開くときに呼ぶ。伏せた高さまで下げて、開いた画面を見せる。伏せた高さのない画面（iPhoneの横向き）では下げられないのでfalseを返す。
    func lowerToShowScreenBehind() -> Bool {
        guard let presentation, presentation.layout.collapsed != nil else { return false }
        if presentation.selected != .collapsed {
            logger.info("in-app browser lower for destination from=\(presentation.selected.rawValue, privacy: .public)")
            select(.collapsed, on: presentation)
        }
        return true
    }

    /// 投稿欄で書き終えたときに呼ぶ。書き始める前の高さへ戻す。
    func restoreAfterCompose() {
        logger.info("in-app browser compose ended")
        guard let previous = detentBeforeCompose else { return }
        detentBeforeCompose = nil
        guard let presentation else { return }
        logger.info("in-app browser restore after compose to=\(previous.rawValue, privacy: .public)")
        select(previous, on: presentation)
    }

    private func select(_ detent: InAppBrowserDetent, on presentation: InAppBrowserPresentationController) {
        presentation.select(detent, animated: true)
        selectionDidChange(presentation)
    }

    /// 開くときの段。最初から全画面で開く設定なら全画面、そうでなければ中くらいの高さ。
    private var openingDetent: InAppBrowserDetent {
        settings.opensInAppBrowserFullScreen ? .large : .medium
    }

    /// 伏せた高さはチューニングから、中くらいの高さは設定から読む。伏せた高さは画面の下端から数え、中くらいの高さは安全領域の中の高さに下の安全領域を足す。
    /// 高さの狭い画面（iPhoneの横向き）では全画面だけにする。
    private func sheetLayout(in window: UIWindow, traits: UITraitCollection) -> InAppBrowserSheetLayout {
        let height = Double(window.bounds.height)
        guard traits.verticalSizeClass != .compact else {
            return InAppBrowserSheetLayout(collapsed: nil, medium: nil, large: height)
        }
        let large = height - Double(window.safeAreaInsets.top) - SpacingScale.s2
        let collapsedHeight = tuning.value(of: TuningCatalog.inAppBrowserCollapsedHeight)
        let inner = settings.inAppBrowserHeight.sheetHeight(available: Double(window.safeAreaHeight), minimum: collapsedHeight)
        let medium = min(inner + Double(window.safeAreaInsets.bottom), large)
        let homeIndicatorSpace = window.safeAreaInsets.bottom > 0 ? tuning.value(of: TuningCatalog.inAppBrowserCollapsedHomeIndicatorSpace) : 0
        return InAppBrowserSheetLayout(collapsed: min(collapsedHeight + homeIndicatorSpace, medium - 1), medium: medium, large: large)
    }

    /// 全画面に広げている間はタイムラインが見えないため、中くらいの高さの値を使い続ける。
    private func reportObscuredHeight(of presentation: InAppBrowserPresentationController) {
        let layout = presentation.layout
        let isCollapsed = presentation.selected == .collapsed
        let height: CGFloat = switch presentation.selected {
        case .collapsed: CGFloat(layout.collapsed ?? 0)
        case .temporary: CGFloat(layout.temporary ?? 0)
        case .medium, .large: CGFloat(layout.medium ?? 0)
        }
        let docks = isCollapsed && canDock(presentation)
        onDockedHeightChange?(docks ? height : 0, true)
        onObscuredHeightChange?(docks ? 0 : height)
    }

    /// 投稿欄のために下げている間は、キーボードの裏へ逃がしているだけなので縮めない。iPadの幅では、シートが画面の幅より狭いので縮めない。
    private func canDock(_ presentation: InAppBrowserPresentationController) -> Bool {
        let traits = presentation.traitCollection
        return !isGrowingFromCollapsed && detentBeforeCompose == nil && traits.horizontalSizeClass == .compact && traits.verticalSizeClass == .regular
    }

    private func selectionDidChange(_ presentation: InAppBrowserPresentationController) {
        collapsedSheetMayMove(presentation.presentedViewController as? InAppBrowserSheet)
        reportObscuredHeight(of: presentation)
        // 全画面で開くSafariを読み込む間に、伏せた高さから離れたら（引いて広げた、横向きにしたなど）、読み込みを待たずに全画面に広げる。
        if let fullScreen, fullScreen.collapsedSheet?.sheetPresentation === presentation {
            // 横向きでは伏せた高さがなくなるが、選んでいる段は伏せたままになる。
            if presentation.selected != .collapsed || presentation.layout.collapsed == nil { expand(fullScreen) }
            return
        }
        onCoverageChange?(presentation.coversScreenBehind)
    }

    /// 指でシートの高さを変えたとき。コードから変えたときは呼ばれない。
    private func userDidChangeSelection(_ presentation: InAppBrowserPresentationController) {
        guard presentation === current?.sheetPresentation else { return }
        logger.info("in-app browser detent \(presentation.selected.rawValue, privacy: .public)")
        detentBeforeCompose = nil
        selectionDidChange(presentation)
    }

    /// - Parameter coversScreenBehind: シートを閉じても、全画面のSafariがまだ後ろの画面を覆っているか。
    private func didClose(_ browserSheet: InAppBrowserSheet?, coversScreenBehind: Bool = false) {
        guard current === browserSheet || current == nil else { return }
        current = nil
        detentBeforeCompose = nil
        isGrowingFromCollapsed = false
        logger.info("in-app browser close")
        // 全画面のSafariが覆ったままなら、戻す動きは見えないので動かさない。動かすと、見えない動きのために画面の合成が働く（検証用のSE3で、広がりきったあとの0.6秒に約100ms分を測った）。
        onDockedHeightChange?(0, !coversScreenBehind)
        onObscuredHeightChange?(0)
        onCoverageChange?(coversScreenBehind)
        onPresenceChange?(false)
    }

    /// 全画面のSafariが閉じたとき。×で閉じたときは、閉じる動きが終わってから重ねたウインドウを隠す。
    /// 読み込みの間（伏せたシートに重ねている間）なら、シートも一緒に下げて閉じ、重ねたウインドウはシートに付いて下がる。
    private func didCloseFullScreen(_ session: FullScreenSession) {
        guard fullScreen === session else { return }
        logger.info("in-app browser full screen closed")
        fullScreen = nil
        session.window.hideAfterSafariDismissal()
        if let sheet = session.collapsedSheet {
            // シートと同じく下へ下げて閉じ、Safariは下がるシートに付いていく。シートが止まっていて合わせるのを止めていたら、始め直す。
            startFollowing(session)
            // 下がりきったら、止めていたSafariの閉じる動き（`InAppBrowserOverlayWindow.holdSafariDismissalSlide`）を終わらせる。
            if !sheet.isBeingDismissed, let presenter = sheet.presentingViewController {
                presenter.dismiss(animated: true) { [weak window = session.window] in window?.finishHeldSafariDismissal() }
            } else {
                session.window.finishHeldSafariDismissal()
            }
            didClose(sheet)
        } else {
            // シートを全画面に広げたまま、その上に全画面のSafariを重ねていたときは、シートがまだ覆っている。
            onCoverageChange?(presentation?.coversScreenBehind ?? false)
        }
    }

    // MARK: - SFSafariViewControllerDelegate

    /// 左上の×で閉じたとき。シートごと閉じる（`InAppBrowserSheet`）。全画面では、左端からのスワイプで閉じたときにも呼ばれる。
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        if let fullScreen, fullScreen.safari === controller {
            didCloseFullScreen(fullScreen)
            return
        }
        logger.info("in-app browser finished by close button")
        guard current?.safari === controller else { return }
        didClose(current)
    }

    // MARK: - UIAdaptivePresentationControllerDelegate

    /// 下へのスワイプで閉じたとき。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let fullScreen, presentationController.presentedViewController === fullScreen.safari {
            didCloseFullScreen(fullScreen)
            return
        }
        guard let browserSheet = presentationController.presentedViewController as? InAppBrowserSheet else { return }
        logger.info("in-app browser dismissed by swipe")
        if let fullScreen, fullScreen.collapsedSheet === browserSheet {
            // 読み込みの間に伏せたシートを閉じたら（下へ払った、重ねた画面をまとめて閉じた）、重ねたSafariも閉じる。
            dropFullScreenOverlay()
        }
        didClose(browserSheet)
    }
}

extension UIWindow {
    /// 窓の高さから上下の安全領域を除いた高さ。アプリ内のSafariと、その高さを選ぶシートの段の元にする（`InAppBrowserHeight`）。
    var safeAreaHeight: CGFloat {
        bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
    }
}
