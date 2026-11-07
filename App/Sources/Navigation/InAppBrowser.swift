import os
import SafariServices
import SciaCore
import UIKit

/// 本文のリンクを、アプリ内のSafariで開く。中くらいの高さのシートで出し、後ろを暗くせず、上に見えるタイムラインを触れるままにする。
/// アプリは手前にいたままなので、読んでいる間もストリーミングが流れ続ける。
///
/// シートの高さは、伏せた高さ（URLのバーだけ見える）、中くらいの高さ、全画面の3段。投稿欄で書いている間は伏せた高さまで下げ、書き終えたら戻す。
/// シートはSafariではなく入れ物（`InAppBrowserSheet`）で出し、高さを変えるのは上端の帯を引いたときだけにする。ページのスワイプでシートが下がらないようにするため。
@MainActor
final class InAppBrowser: NSObject, @MainActor SFSafariViewControllerDelegate, UISheetPresentationControllerDelegate {
    /// シートが画面の下から覆っている高さが変わったときに呼ぶ。閉じたら0を渡す。タイムラインの下に、シートより上へ出せるだけの余白を取るために使う。
    var onObscuredHeightChange: ((CGFloat) -> Void)?
    /// シートを全画面に広げてタイムラインを覆ったか、覆うのをやめたときに呼ぶ。覆っている間は、タイムラインの投稿を見たと報告させない。
    var onCoverageChange: ((Bool) -> Void)?
    /// シートを出したか、閉じたときに呼ぶ。中身を差し替えるときは呼ばない。
    var onPresenceChange: ((Bool) -> Void)?

    private let tuning: TuningStore
    private let settings: AppSettings
    /// シートを出した窓。中くらいの高さは、この窓の安全領域の中の高さから、段を決めるたびに決める（`InAppBrowserHeight`）。
    /// 窓の安全領域は窓とシーンで決まり、シートの並べ方に左右されないので、段の計算の中で読んでも、
    /// シート自身の安全領域を読んだときのような入れ子（`reportObscuredHeightAfterResolving`）にならない。
    private weak var window: UIWindow?
    private weak var current: InAppBrowserSheet?
    /// 段ごとに解決した高さ（安全領域の中の高さ）。シートの見た目の位置はビューの枠に出ず（シートのビューの枠は画面全体のまま）、
    /// 出したあとに測れないため、高さを決めるところで受け取って覚えておく。
    private var resolvedHeights: [UISheetPresentationController.Detent.Identifier: CGFloat] = [:]
    /// 高さを決め終えたあとに、覆う高さを知らせると決めてある。
    private var reportsObscuredHeightAfterResolving = false
    /// 投稿欄で書き始めて伏せる前の高さ。書き終えたらここへ戻す。書いている間に手で高さを変えたら、手で選んだ高さを尊重して戻さない。
    private var detentBeforeCompose: UISheetPresentationController.Detent.Identifier?
    private let logger = SciaLog.logger(category: "browser")

    init(tuning: TuningStore = AppDependencies.tuning, settings: AppSettings = AppDependencies.settings) {
        self.tuning = tuning
        self.settings = settings
    }

    /// シートを出している。中身を差し替える途中も含む。
    var isPresented: Bool { current != nil }

    /// `url`はhttpかhttpsに限る。ほかのスキームを渡すとSFSafariViewControllerが例外で落ちるため、呼び出し側で`LinkBrowser`に振り分けさせる。
    /// シートを出している間に別のリンクが押されたら、高さを保ったまま中身を差し替える。
    func open(_ url: URL, from root: UIViewController) {
        guard let window = root.viewIfLoaded?.window else {
            // 窓にない画面からはシートを出せないので、開かない。
            logger.error("in-app browser open ignored without window")
            return
        }
        self.window = window
        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        let browserSheet = InAppBrowserSheet(safari: safari, handleHeight: CGFloat(tuning.value(of: TuningCatalog.inAppBrowserHandleHeight)))
        browserSheet.modalPresentationStyle = .pageSheet
        if let sheet = browserSheet.sheetPresentationController {
            sheet.detents = [detent(Self.collapsedIdentifier, for: browserSheet), detent(Self.mediumIdentifier, for: browserSheet), .large()]
            // 中くらいの高さまでは後ろを暗くせず、タイムラインを触れるままにする。
            sheet.largestUndimmedDetentIdentifier = Self.mediumIdentifier
            // 選んでいなければいちばん低い段で出るため、設定の高さの段を選んでおく。
            sheet.selectedDetentIdentifier = openingIdentifier
            sheet.prefersGrabberVisible = true
            sheet.delegate = self
        }
        if let current, let presenter = current.presentingViewController, !current.isBeingDismissed {
            browserSheet.sheetPresentationController?.selectedDetentIdentifier = current.sheetPresentationController?.selectedDetentIdentifier
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
        if grows {
            browserSheet.sheetPresentationController?.selectedDetentIdentifier = Self.collapsedIdentifier
        }
        logger.info("in-app browser open grows=\(grows, privacy: .public)")
        onPresenceChange?(true)
        let opening = openingIdentifier
        root.frontmostPresented.present(browserSheet, animated: true) { [weak self, weak browserSheet] in
            guard let self, let browserSheet, self.current === browserSheet, let sheet = browserSheet.sheetPresentationController else { return }
            if grows {
                guard sheet.selectedDetentIdentifier == Self.collapsedIdentifier else { return }
                self.select(opening, on: sheet)
            } else {
                // 全画面で開いたときに、タイムラインを覆ったことを知らせる。
                self.selectionDidChange(sheet)
            }
        }
        browserSheet.presentSafari()
    }

    /// 投稿欄で書き始めたときに呼ぶ。シートは投稿欄より手前に出るため、伏せた高さまで下げてキーボードの裏へ逃がす。
    func lowerForCompose() {
        guard let sheet = current?.sheetPresentationController, !(current?.isBeingDismissed ?? true) else { return }
        let selected = sheet.selectedDetentIdentifier ?? Self.collapsedIdentifier
        guard selected != Self.collapsedIdentifier else { return }
        detentBeforeCompose = selected
        logger.info("in-app browser lower for compose from=\(selected.rawValue, privacy: .public)")
        select(Self.collapsedIdentifier, on: sheet)
    }

    /// 投稿欄で書き終えたときに呼ぶ。書き始める前の高さへ戻す。
    func restoreAfterCompose() {
        logger.info("in-app browser compose ended")
        guard let previous = detentBeforeCompose else { return }
        detentBeforeCompose = nil
        guard let sheet = current?.sheetPresentationController, !(current?.isBeingDismissed ?? true) else { return }
        logger.info("in-app browser restore after compose to=\(previous.rawValue, privacy: .public)")
        select(previous, on: sheet)
    }

    private func select(_ identifier: UISheetPresentationController.Detent.Identifier, on sheet: UISheetPresentationController) {
        sheet.animateChanges {
            sheet.selectedDetentIdentifier = identifier
        }
        selectionDidChange(sheet)
    }

    /// 開くときの段。最初から全画面で開く設定なら全画面、そうでなければ中くらいの高さ。
    private var openingIdentifier: UISheetPresentationController.Detent.Identifier {
        settings.opensInAppBrowserFullScreen ? .large : Self.mediumIdentifier
    }

    private static let collapsedIdentifier = UISheetPresentationController.Detent.Identifier("net.mizle.scia.inAppBrowser.collapsed")
    private static let mediumIdentifier = UISheetPresentationController.Detent.Identifier("net.mizle.scia.inAppBrowser.medium")

    /// 中くらいの高さは設定から、伏せた高さはチューニングから読む。中くらいの高さは伏せた高さより低くしない。値は安全領域の中の高さで、下端に付くシートでは、これに下の安全領域が足される。
    /// タイムラインの余白も安全領域の外から数えるので、知らせるときに足す。設定やチューニングを変えたら、次にシートの高さを決め直すとき（開き直す、段を変える）に効く。
    /// 高さの狭い画面（iPhoneの横向き）では、中くらいの高さの段を出さず、シートは全画面になる。
    /// 段は低い順に並べる決まりがあるため、伏せた高さは中くらいの高さより低く抑える。チューニングの組み合わせによっては、伏せた高さが設定より低くなる。
    private func detent(_ identifier: UISheetPresentationController.Detent.Identifier, for browserSheet: InAppBrowserSheet) -> UISheetPresentationController.Detent {
        .custom(identifier: identifier) { [weak self, weak browserSheet] context in
            guard let self else { return nil }
            let value: CGFloat? = switch identifier {
            case Self.collapsedIdentifier:
                min(CGFloat(self.tuning.value(of: TuningCatalog.inAppBrowserCollapsedHeight)), (self.mediumHeight(in: context) ?? .greatestFiniteMagnitude) - 1)
            default:
                self.mediumHeight(in: context)
            }
            if let browserSheet, self.current === browserSheet {
                self.resolvedHeights[identifier] = value
                self.reportObscuredHeightAfterResolving()
            }
            return value
        }
    }

    /// 高さを決めている間は、知らせも安全領域の読み出しもしない。知らせを受けたタイムラインが安全領域を変えると、UIKitが高さを決めている途中のシートに
    /// 位置を聞き直し、入れ子になって落ちるため。次のメインループで、決め終えた高さを知らせる。
    private func reportObscuredHeightAfterResolving() {
        guard !reportsObscuredHeightAfterResolving else { return }
        reportsObscuredHeightAfterResolving = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reportsObscuredHeightAfterResolving = false
            guard let sheet = current?.sheetPresentationController, !(current?.isBeingDismissed ?? true) else { return }
            reportObscuredHeight(of: sheet)
        }
    }

    private func mediumHeight(in context: any UISheetPresentationControllerDetentResolutionContext) -> CGFloat? {
        guard context.containerTraitCollection.verticalSizeClass != .compact else { return nil }
        guard let window else { return nil }
        let minimum = tuning.value(of: TuningCatalog.inAppBrowserCollapsedHeight)
        return min(CGFloat(settings.inAppBrowserHeight.sheetHeight(available: Double(window.safeAreaHeight), minimum: minimum)), context.maximumDetentValue)
    }

    /// 全画面に広げている間はタイムラインが見えないため、中くらいの高さの値を使い続ける。
    private func reportObscuredHeight(of sheet: UISheetPresentationController) {
        let selected = sheet.selectedDetentIdentifier == Self.collapsedIdentifier ? Self.collapsedIdentifier : Self.mediumIdentifier
        let bottomInset = sheet.presentedViewController.view.safeAreaInsets.bottom
        onObscuredHeightChange?(resolvedHeights[selected].map { $0 + bottomInset } ?? 0)
    }

    private func selectionDidChange(_ sheet: UISheetPresentationController) {
        reportObscuredHeight(of: sheet)
        onCoverageChange?(sheet.selectedDetentIdentifier == .large)
    }

    private func didClose(_ browserSheet: InAppBrowserSheet?) {
        guard current === browserSheet || current == nil else { return }
        current = nil
        detentBeforeCompose = nil
        resolvedHeights = [:]
        logger.info("in-app browser close")
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

    // MARK: - UISheetPresentationControllerDelegate

    /// つまみでシートの高さを変えたとき。コードから変えたときは呼ばれない。中身を差し替えるときは、高さを引き継ぐので覆い方は変わらない。
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
        guard sheet.presentedViewController === current else { return }
        logger.info("in-app browser detent \(sheet.selectedDetentIdentifier?.rawValue ?? "nil", privacy: .public)")
        detentBeforeCompose = nil
        selectionDidChange(sheet)
    }

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
