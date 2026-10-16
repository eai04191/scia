import os
import SafariServices
import SciaCore
import UIKit

/// 本文のリンクを、アプリ内のSafariで開く。中くらいの高さのシートで出し、後ろを暗くせず、上に見える一覧を触れるままにする。
/// アプリは手前にいたままなので、読んでいる間もストリーミングが流れ続ける。
@MainActor
final class InAppBrowser: NSObject, @MainActor SFSafariViewControllerDelegate, UISheetPresentationControllerDelegate {
    /// シートが画面の下から覆っている高さが変わったときに呼ぶ。閉じたら0を渡す。一覧の下に、シートより上へ出せるだけの余白を取るために使う。
    var onObscuredHeightChange: ((CGFloat) -> Void)?
    /// シートを全画面に広げて一覧を覆ったか、覆うのをやめたときに呼ぶ。覆っている間は、一覧の投稿を見たと報告させない。
    var onCoverageChange: ((Bool) -> Void)?

    private weak var current: SFSafariViewController?
    private let logger = SciaLog.logger(category: "browser")

    /// `url`はhttpかhttpsに限る。ほかのスキームを渡すとSFSafariViewControllerが例外で落ちるため、呼び出し側で`LinkBrowser`に振り分けさせる。
    /// シートを出している間に別のリンクが押されたら、高さを保ったまま中身を差し替える。
    func open(_ url: URL, from root: UIViewController) {
        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        safari.modalPresentationStyle = .pageSheet
        if let sheet = safari.sheetPresentationController {
            sheet.detents = [medium(for: safari), .large()]
            // 中くらいの高さのあいだは後ろを暗くせず、一覧を触れるままにする。
            sheet.largestUndimmedDetentIdentifier = Self.mediumIdentifier
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
        logger.info("in-app browser open")
        root.frontmostPresented.present(safari, animated: true)
    }

    private static let mediumIdentifier = UISheetPresentationController.Detent.Identifier("net.mizle.scia.inAppBrowser.medium")

    /// システムの中くらいの高さと同じ高さで、その値を一覧の下の余白に使う。
    /// シートの見た目の位置はビューの枠に出ず（シートのビューの枠は画面全体のまま）、出したあとに測れないため、高さを決めるところで受け取る。
    /// 値は安全領域の中の高さで、下端に付くシートでは、これに下の安全領域が足される。一覧の余白も安全領域の外から数えるので、そのまま渡す。
    /// 全画面に広げている間は一覧が見えないため、中くらいの高さの値を使い続ける。高さの狭い画面（iPhoneの横向き）では中くらいの高さがなく、シートは全画面になるため0を渡す。
    private func medium(for safari: SFSafariViewController) -> UISheetPresentationController.Detent {
        .custom(identifier: Self.mediumIdentifier) { [weak self, weak safari] context in
            let value = UISheetPresentationController.Detent.medium().resolvedValue(in: context)
            if let self, let safari, self.current === safari {
                self.onObscuredHeightChange?(value.map { $0 + safari.view.safeAreaInsets.bottom } ?? 0)
            }
            return value
        }
    }

    private func didClose(_ safari: SFSafariViewController) {
        guard current === safari || current == nil else { return }
        current = nil
        logger.info("in-app browser close")
        onObscuredHeightChange?(0)
        onCoverageChange?(false)
    }

    // MARK: - SFSafariViewControllerDelegate

    /// 左上の×で閉じたとき。
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        didClose(controller)
    }

    // MARK: - UISheetPresentationControllerDelegate

    /// つまみでシートの高さを変えたとき。中身を差し替えるときは、高さを引き継ぐので覆い方は変わらない。
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
        guard sheet.presentedViewController === current else { return }
        let covers = sheet.selectedDetentIdentifier == .large
        logger.info("in-app browser detent large=\(covers, privacy: .public)")
        onCoverageChange?(covers)
    }

    /// 下へのスワイプで閉じたとき。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let safari = presentationController.presentedViewController as? SFSafariViewController else { return }
        didClose(safari)
    }
}
