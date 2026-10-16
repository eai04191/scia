import os
import SafariServices
import SciaCore
import UIKit

/// 本文のリンクを、アプリ内のSafariで開く。中くらいの高さのシートで出し、後ろを暗くせず、上に見える一覧を触れるままにする。
/// アプリは手前にいたままなので、読んでいる間もストリーミングが流れ続ける。
///
/// シートの高さは、伏せた高さ（URLのバーだけ見える）、中くらいの高さ、全画面の3段。投稿欄で書いている間は伏せた高さまで下げ、書き終えたら戻す。
@MainActor
final class InAppBrowser: NSObject, @MainActor SFSafariViewControllerDelegate, UISheetPresentationControllerDelegate {
    /// シートが画面の下から覆っている高さが変わったときに呼ぶ。閉じたら0を渡す。一覧の下に、シートより上へ出せるだけの余白を取るために使う。
    var onObscuredHeightChange: ((CGFloat) -> Void)?
    /// シートを全画面に広げて一覧を覆ったか、覆うのをやめたときに呼ぶ。覆っている間は、一覧の投稿を見たと報告させない。
    var onCoverageChange: ((Bool) -> Void)?
    /// シートを出したか、閉じたときに呼ぶ。中身を差し替えるときは呼ばない。
    var onPresenceChange: ((Bool) -> Void)?

    private let tuning: TuningStore
    private weak var current: SFSafariViewController?
    /// 段ごとに解決した高さ（下の安全領域を含む）。シートの見た目の位置はビューの枠に出ず（シートのビューの枠は画面全体のまま）、
    /// 出したあとに測れないため、高さを決めるところで受け取って覚えておく。
    private var resolvedHeights: [UISheetPresentationController.Detent.Identifier: CGFloat] = [:]
    /// 投稿欄で書き始めて伏せる前の高さ。書き終えたらここへ戻す。書いている間に手で高さを変えたら、手で選んだ高さを尊重して戻さない。
    private var detentBeforeCompose: UISheetPresentationController.Detent.Identifier?
    private let logger = SciaLog.logger(category: "browser")

    init(tuning: TuningStore = AppDependencies.tuning) {
        self.tuning = tuning
    }

    /// シートを出している。中身を差し替える途中も含む。
    var isPresented: Bool { current != nil }

    /// `url`はhttpかhttpsに限る。ほかのスキームを渡すとSFSafariViewControllerが例外で落ちるため、呼び出し側で`LinkBrowser`に振り分けさせる。
    /// シートを出している間に別のリンクが押されたら、高さを保ったまま中身を差し替える。
    func open(_ url: URL, from root: UIViewController) {
        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        safari.modalPresentationStyle = .pageSheet
        if let sheet = safari.sheetPresentationController {
            sheet.detents = [detent(Self.collapsedIdentifier, for: safari), detent(Self.mediumIdentifier, for: safari), .large()]
            // 中くらいの高さまでは後ろを暗くせず、一覧を触れるままにする。
            sheet.largestUndimmedDetentIdentifier = Self.mediumIdentifier
            // 選んでいなければいちばん低い段で出るため、中くらいの高さを選んでおく。
            sheet.selectedDetentIdentifier = Self.mediumIdentifier
            sheet.prefersGrabberVisible = true
            // ページのスクロールでシートを広げない。広げるのはつまみを引いたときだけ。
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.delegate = self
        }
        if let current, let presenter = current.presentingViewController, !current.isBeingDismissed {
            safari.sheetPresentationController?.selectedDetentIdentifier = current.sheetPresentationController?.selectedDetentIdentifier
            self.current = safari
            logger.info("in-app browser replace")
            // 同じ位置に同じ大きさで出し直すので、動かさずに入れ替える。
            current.dismiss(animated: false) {
                presenter.present(safari, animated: false)
            }
            return
        }
        current = safari
        detentBeforeCompose = nil
        logger.info("in-app browser open")
        onPresenceChange?(true)
        root.frontmostPresented.present(safari, animated: true)
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

    private static let collapsedIdentifier = UISheetPresentationController.Detent.Identifier("net.mizle.scia.inAppBrowser.collapsed")
    private static let mediumIdentifier = UISheetPresentationController.Detent.Identifier("net.mizle.scia.inAppBrowser.medium")

    /// 高さはチューニングから読む。値は安全領域の中の高さで、下端に付くシートでは、これに下の安全領域が足される。
    /// 一覧の余白も安全領域の外から数えるので、足したものを覚える。チューニングを変えたら、次にシートの高さを決め直すとき（開き直す、段を変える）に効く。
    /// 高さの狭い画面（iPhoneの横向き）では、中くらいの高さの段を出さず、シートは全画面になる。
    /// 段は低い順に並べる決まりがあるため、伏せた高さは中くらいの高さより低く抑える。チューニングの組み合わせによっては、伏せた高さが設定より低くなる。
    private func detent(_ identifier: UISheetPresentationController.Detent.Identifier, for safari: SFSafariViewController) -> UISheetPresentationController.Detent {
        .custom(identifier: identifier) { [weak self, weak safari] context in
            guard let self else { return nil }
            let value: CGFloat? = switch identifier {
            case Self.collapsedIdentifier:
                min(CGFloat(self.tuning.value(of: TuningCatalog.inAppBrowserCollapsedHeight)), (self.mediumHeight(in: context) ?? .greatestFiniteMagnitude) - 1)
            default:
                self.mediumHeight(in: context)
            }
            if let safari, self.current === safari {
                self.resolvedHeights[identifier] = value.map { $0 + safari.view.safeAreaInsets.bottom }
                if let sheet = safari.sheetPresentationController { self.reportObscuredHeight(of: sheet) }
            }
            return value
        }
    }

    private func mediumHeight(in context: any UISheetPresentationControllerDetentResolutionContext) -> CGFloat? {
        guard context.containerTraitCollection.verticalSizeClass != .compact else { return nil }
        return context.maximumDetentValue * CGFloat(tuning.value(of: TuningCatalog.inAppBrowserMediumFraction))
    }

    /// 全画面に広げている間は一覧が見えないため、中くらいの高さの値を使い続ける。
    private func reportObscuredHeight(of sheet: UISheetPresentationController) {
        let selected = sheet.selectedDetentIdentifier == Self.collapsedIdentifier ? Self.collapsedIdentifier : Self.mediumIdentifier
        onObscuredHeightChange?(resolvedHeights[selected] ?? 0)
    }

    private func selectionDidChange(_ sheet: UISheetPresentationController) {
        reportObscuredHeight(of: sheet)
        onCoverageChange?(sheet.selectedDetentIdentifier == .large)
    }

    private func didClose(_ safari: SFSafariViewController) {
        guard current === safari || current == nil else { return }
        current = nil
        detentBeforeCompose = nil
        resolvedHeights = [:]
        logger.info("in-app browser close")
        onObscuredHeightChange?(0)
        onCoverageChange?(false)
        onPresenceChange?(false)
    }

    // MARK: - SFSafariViewControllerDelegate

    /// 左上の×で閉じたとき。
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        logger.info("in-app browser finished by close button")
        didClose(controller)
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
        guard let safari = presentationController.presentedViewController as? SFSafariViewController else { return }
        logger.info("in-app browser dismissed by swipe")
        didClose(safari)
    }
}
