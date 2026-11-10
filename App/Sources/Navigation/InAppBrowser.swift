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
    var onDockedHeightChange: ((CGFloat) -> Void)?
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

    init(tuning: TuningStore = AppDependencies.tuning, settings: AppSettings = AppDependencies.settings, clock: any Clock<Duration> = AppDependencies.clock) {
        self.tuning = tuning
        self.settings = settings
        self.clock = clock
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

    private func makeSheet(safari: SFSafariViewController) -> InAppBrowserSheet {
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
            handleHeight: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserHandleHeight)),
            barGrab: InAppBrowserSheet.BarGrab(
                height: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserBarGrabHeight)),
                inset: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserBarGrabInset)),
                isVisible: tuning.value(of: TuningCatalog.inAppBrowserShowsBarGrabArea)
            ),
            safariResizeDelay: .seconds(tuning.value(of: TuningCatalog.inAppBrowserSafariResizeDelay)),
            safariTopInset: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserSafariTopInset)),
            clock: clock,
            configuration: configuration
        )
        browserSheet.presentationDelegate = self
        browserSheet.onPresentationCreated = { [weak self] presentation in
            presentation.onSelectionChange = { [weak self, weak presentation] in
                guard let self, let presentation else { return }
                self.userDidChangeSelection(presentation)
            }
            presentation.onLayoutChange = { [weak self, weak presentation] in
                guard let self, let presentation else { return }
                self.selectionDidChange(presentation)
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
        let large = height - Double(window.safeAreaInsets.top) - tuning.value(of: TuningCatalog.inAppBrowserSheetLargeTopGap)
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
        onDockedHeightChange?(docks ? height : 0)
        onObscuredHeightChange?(docks ? 0 : height)
    }

    /// 投稿欄のために下げている間は、キーボードの裏へ逃がしているだけなので縮めない。iPadの幅では、シートが画面の幅より狭いので縮めない。
    private func canDock(_ presentation: InAppBrowserPresentationController) -> Bool {
        let traits = presentation.traitCollection
        return !isGrowingFromCollapsed && detentBeforeCompose == nil && traits.horizontalSizeClass == .compact && traits.verticalSizeClass == .regular
    }

    private func selectionDidChange(_ presentation: InAppBrowserPresentationController) {
        reportObscuredHeight(of: presentation)
        onCoverageChange?(presentation.coversScreenBehind)
    }

    /// 指でシートの高さを変えたとき。コードから変えたときは呼ばれない。
    private func userDidChangeSelection(_ presentation: InAppBrowserPresentationController) {
        guard presentation === current?.sheetPresentation else { return }
        logger.info("in-app browser detent \(presentation.selected.rawValue, privacy: .public)")
        detentBeforeCompose = nil
        selectionDidChange(presentation)
    }

    private func didClose(_ browserSheet: InAppBrowserSheet?) {
        guard current === browserSheet || current == nil else { return }
        current = nil
        detentBeforeCompose = nil
        isGrowingFromCollapsed = false
        logger.info("in-app browser close")
        onDockedHeightChange?(0)
        onObscuredHeightChange?(0)
        onCoverageChange?(false)
        onPresenceChange?(false)
    }

    // MARK: - SFSafariViewControllerDelegate

    /// 左上の×で閉じたとき。シートごと閉じる（`InAppBrowserSheet`）。
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        logger.info("in-app browser finished by close button")
        guard current?.safari === controller else { return }
        didClose(current)
    }

    // MARK: - UIAdaptivePresentationControllerDelegate

    /// 下へのスワイプで閉じたとき。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let browserSheet = presentationController.presentedViewController as? InAppBrowserSheet else { return }
        logger.info("in-app browser dismissed by swipe")
        didClose(browserSheet)
    }
}

extension UIWindow {
    /// 窓の高さから上下の安全領域を除いた高さ。アプリ内のSafariと、その高さを選ぶシートの段の元にする（`InAppBrowserHeight`）。
    var safeAreaHeight: CGFloat {
        bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
    }
}
