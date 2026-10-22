import os
import SciaCore
import UIKit

/// 投稿欄の下に出すシート。メディアを選ぶシートと絵文字のパレットのシートを、投稿欄のバーを留めておく間の扱いで同じに扱う。
@MainActor
protocol ComposeBottomSheet: AnyObject {
    /// 閉じることが決まったあと。
    var isClosing: Bool { get }
    /// プログラムから閉じる。`notifiesWillClose`なら、閉じることが決まった知らせ（キーボードを戻す）を出す。
    func close(notifiesWillClose: Bool)
}

extension MediaPickerSheet: ComposeBottomSheet {}

/// カスタム絵文字のパレットを載せるシート。低い段と全画面の2段で出す。
///
/// 低い段はメディアを選ぶシートと同じく、投稿欄のバーをシートの上端に留め、書いている本文を見せる。
/// 全画面になるのは、上の掴みを引き上げたときと、検索欄にキーボードを出したときだけにする。絵文字をスクロールして広がらないよう、
/// スクロールが端に届いても広げない。検索欄にキーボードを出すと、選んだ段にかかわらずUIKitがシートを全画面まで広げる（`scia-debug://sheet-keyboard`で確かめた）。
@MainActor
final class EmojiPaletteSheet: NSObject, ComposeBottomSheet {
    /// 閉じることが決まった時点で呼ぶ。キーボードをシートが下がるのと同時に上げるために使う。
    var onWillClose: () -> Void = {}
    /// 閉じ終わったときに呼ぶ。
    var onDidClose: () -> Void = {}
    private(set) var isClosing = false

    private let controller = UIViewController()
    private let palette: EmojiPaletteView
    private let logger = SciaLog.logger(category: "compose")
    private static let lowDetent = UISheetPresentationController.Detent.Identifier("low")

    /// - Parameter lowHeight: 低いときのシートの高さ。画面の下の安全領域は含まない。
    init(palette: EmojiPaletteView, lowHeight: CGFloat) {
        self.palette = palette
        super.init()
        controller.view.backgroundColor = .clear
        palette.translatesAutoresizingMaskIntoConstraints = false
        palette.removeFromSuperview()
        controller.view.addSubview(palette)
        NSLayoutConstraint.activate([
            palette.topAnchor.constraint(equalTo: controller.view.topAnchor),
            palette.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            palette.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            palette.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
        ])
        if let sheet = controller.sheetPresentationController {
            let low = UISheetPresentationController.Detent.custom(identifier: Self.lowDetent) { _ in lowHeight }
            sheet.detents = [low, .large()]
            sheet.selectedDetentIdentifier = Self.lowDetent
            sheet.largestUndimmedDetentIdentifier = Self.lowDetent
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.prefersGrabberVisible = true
            sheet.delegate = self
        }
    }

    func present(from host: UIViewController) {
        host.present(controller, animated: true)
    }

    func close(notifiesWillClose: Bool) {
        guard controller.presentingViewController != nil else { return }
        if notifiesWillClose {
            notifyWillClose()
        } else {
            isClosing = true
        }
        // プログラムから閉じたときは`presentationControllerDidDismiss`が呼ばれないので、閉じ終わりをここで知らせる。
        controller.dismiss(animated: true) { [weak self] in self?.onDidClose() }
    }

    /// 検索をやめて、キーボードを下げ、低い段に戻す。
    func endSearch() {
        palette.searchField.resignFirstResponder()
        controller.sheetPresentationController?.animateChanges {
            controller.sheetPresentationController?.selectedDetentIdentifier = Self.lowDetent
        }
    }

    private func notifyWillClose() {
        guard !isClosing else { return }
        isClosing = true
        logger.info("emoji palette sheet: will close")
        onWillClose()
    }
}

extension EmojiPaletteSheet: UISheetPresentationControllerDelegate {
    /// スワイプして閉じるとき、閉じ終わるのを待たず、指を離して閉じることが決まった時点で知らせる。
    /// 閉じ終わってからキーボードを出すと、一拍遅れて上がってくる。
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        guard let coordinator = presentationController.presentedViewController.transitionCoordinator else { return }
        coordinator.notifyWhenInteractionChanges { [weak self] context in
            guard !context.isCancelled else { return }
            self?.notifyWillClose()
        }
    }

    /// スワイプして閉じたときだけ呼ばれる。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        isClosing = true
        onDidClose()
    }
}
