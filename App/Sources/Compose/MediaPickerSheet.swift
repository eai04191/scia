import os
import PhotosUI
import SciaCore
import UIKit

/// 投稿に添付するメディアを選ぶ、システムの写真ピッカー。低い（部品なし）と最大（部品付き）の2段のシートで直接出す。
///
/// 選び方と、ここで頼っている公式に保証されていない挙動は docs/media-attachment.md にまとめている。
@MainActor
final class MediaPickerSheet: NSObject {
    /// 選択が変わるたびに、今の選択を順に渡す。
    var onSelectionChange: ([PHPickerResult]) -> Void = { _ in }
    /// 閉じることが決まった時点で呼ぶ。キーボードをシートが下がるのと同時に上げるために使う。
    var onWillClose: () -> Void = {}
    /// 閉じ終わったときに呼ぶ。
    var onDidClose: () -> Void = {}

    private let picker: PHPickerViewController
    private var selectedIDs: [String]
    private let logger = SciaLog.logger(category: "compose")
    /// 高さが変わるたびにグリッドを最初の位置に戻す。前に選んだものがある状態で開いたときは戻さない。
    /// そのときピッカーは前に選んだ写真の位置で開くが、戻す先はそこではなく一番上で、選んだ写真を見失わせてしまう。
    /// 戻さない代わりに、広げると最新の段が見出しの分だけ潜り、広げて低くした後は写真の上を払ってもシートが広がらずにスクロールする。
    /// 選んだものを足し引きするために開き直したなら、選んだ写真の近くから離れない方を取る。
    private let resetsScrollOnDetentChange: Bool
    private static let lowDetent = UISheetPresentationController.Detent.Identifier("low")
    /// 閉じることが決まったあと。キーボードを二度上げないよう、閉じる知らせは一度だけにする。
    private(set) var isClosing = false

    /// - Parameters:
    ///   - selectedIDs: 前に選んだメディアのID。開き直したときに選んだ状態で出す。
    ///   - selectionLimit: 選べる枚数の上限。接続先のサーバーの添付の上限にする。
    ///   - lowHeight: 低いときのシートの高さ。画面の下の安全領域は含まない。
    init(selectedIDs: [String], selectionLimit: Int, lowHeight: CGFloat) {
        self.selectedIDs = selectedIDs
        resetsScrollOnDetentChange = selectedIDs.isEmpty
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = selectionLimit
        configuration.selection = .continuousAndOrdered
        configuration.preselectedAssetIdentifiers = selectedIDs
        // 低いときは余白をなくしてバーを消す。最大に広げたら余白を戻してバーを出す。
        configuration.edgesWithoutContentMargins = .all
        picker = PHPickerViewController(configuration: configuration)
        super.init()
        picker.delegate = self
        if let sheet = picker.sheetPresentationController {
            let low = UISheetPresentationController.Detent.custom(identifier: Self.lowDetent) { _ in lowHeight }
            sheet.detents = [low, .large()]
            sheet.selectedDetentIdentifier = Self.lowDetent
            sheet.largestUndimmedDetentIdentifier = Self.lowDetent
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersGrabberVisible = true
            sheet.delegate = self
        }
    }

    func present(from host: UIViewController) {
        host.present(picker, animated: true)
    }

    /// プログラムから閉じる。払って閉じられなくなったときも、こちらは効く。
    func close(notifiesWillClose: Bool) {
        guard picker.presentingViewController != nil else { return }
        if notifiesWillClose {
            notifyWillClose()
        } else {
            isClosing = true
        }
        // プログラムから閉じたときは`presentationControllerDidDismiss`が呼ばれないので、閉じ終わりをここで知らせる。
        picker.dismiss(animated: true) { [weak self] in self?.onDidClose() }
    }

    private func notifyWillClose() {
        guard !isClosing else { return }
        isClosing = true
        logger.info("media picker: will close")
        onWillClose()
    }
}

extension MediaPickerSheet: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let ids = results.compactMap(\.assetIdentifier)
        // 選択をその場で受け取る設定では、✓を押すと今の選択がそのままもう一度届く。選択が変わらずに届いたら✓とみなして閉じる。
        if ids == selectedIDs {
            logger.info("media picker: same selection arrived, treating as done (count=\(ids.count))")
            close(notifiesWillClose: true)
            return
        }
        selectedIDs = ids
        logger.info("media picker: selection changed (count=\(ids.count))")
        onSelectionChange(results)
        // 1枚選ぶとピッカーが自分のisModalInPresentationを立て、払っても閉じられなくなる。
        // 選択はその場で受け取っていて閉じても失われないので、下ろしておく。
        DispatchQueue.main.async { [logger] in
            guard picker.isModalInPresentation else { return }
            picker.isModalInPresentation = false
            logger.info("media picker: reset isModalInPresentation")
        }
    }
}

extension MediaPickerSheet: UISheetPresentationControllerDelegate {
    /// 最大に広げたら部品を出し、低くしたら消す。
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheet: UISheetPresentationController) {
        let isLarge = sheet.selectedDetentIdentifier == .large
        var update = PHPickerConfiguration.Update()
        update.edgesWithoutContentMargins = isLarge ? [] : .all
        picker.updatePicker(using: update)
        // 余白を変えても、ピッカーはグリッドの位置を合わせ直さない。広げると最新の写真の段が見出しの裏に潜り、低くすると一番上からずれて、
        // 写真の上を払ってもシートが広がらずにグリッドがスクロールする。写真の上を払って広げたときは、同じ指の動きでグリッドもスクロールする。
        // そのため高さが変わるたびに最初の位置に戻す。余白の変更と同じ処理の中で戻すと、変更前の余白で戻ってしまうので、次の順番に回す。
        // 最大でスクロールして古い写真を見ていた場合も、低くすると最新に戻る。
        guard resetsScrollOnDetentChange else { return }
        let detent = sheet.selectedDetentIdentifier
        DispatchQueue.main.async { [weak self, weak sheet] in
            guard let self, sheet?.selectedDetentIdentifier == detent else { return }
            logger.info("media picker: scroll to initial position after detent change (large=\(isLarge))")
            picker.scrollToInitialPosition()
        }
    }

    /// 払って閉じるとき、閉じ終わるのを待たず、指を離して閉じることが決まった時点で知らせる。
    /// 閉じ終わってからキーボードを出すと、一拍遅れて上がってくる。
    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        guard let coordinator = presentationController.presentedViewController.transitionCoordinator else { return }
        coordinator.notifyWhenInteractionChanges { [weak self] context in
            guard !context.isCancelled else { return }
            self?.notifyWillClose()
        }
    }

    /// 払って閉じたときだけ呼ばれる。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        isClosing = true
        onDidClose()
    }
}
