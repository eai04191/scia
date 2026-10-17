import os
import SciaCore
import UIKit

extension TimelineViewController {
    /// 閲覧注意の投稿と、注意書きのある投稿は、タップするまで添付ファイルを覆う。
    /// 説明にならない代替テキストは、ALTの目印にもビューアにも読み上げにも出さないよう、ここで除いておく。
    func mediaContent(for status: Status) -> MediaGridView.Content? {
        guard !status.mediaAttachments.isEmpty else { return nil }
        let isSensitive = status.sensitive || !status.spoilerText.isEmpty
        return MediaGridView.Content(
            attachments: status.mediaAttachments.map { $0.filteringAltText(ignoresUseless: settings.ignoresUselessAltText) },
            isCovered: isSensitive && !revealedMediaStatusIDs.contains(status.id),
            tallestAspectRatio: tuning.value(of: TuningCatalog.mediaTallestAspectRatio),
            thumbnailPolicy: MediaThumbnailPolicy(
                allowsOriginal: MediaThumbnailSelection.allowsOriginal(
                    on: network.conditions,
                    usesOriginalOnExpensiveNetwork: settings.usesOriginalThumbnailsOnExpensiveNetwork
                ),
                upscaleTolerance: tuning.value(of: TuningCatalog.mediaThumbnailUpscaleTolerance)
            )
        )
    }

    /// 覆いを外す。同じ投稿をブーストした行と通知の行もまとめて描き直す。覆いと中身は同じ大きさのため、行の高さは変わらない。
    func revealMedia(of statusID: Status.ID) {
        revealedMediaStatusIDs.insert(statusID)
        let ids = displayedItemIDs.filter { status(for: $0)?.displayed.id == statusID }
        reconfigure(Set(ids))
    }

    /// 添付ファイルのビューアで覆っている。ビューアは閉じる操作の間に一覧を透かすため、開いている間も一覧を画面に残す。
    /// 閉じ終わりに報告し直せるよう、閉じている途中のビューアは数えない。
    /// ビューアはアプリ内のSafariのシートの上に重ねていることがあるため、重ねている画面をたどって探す。
    var isCoveredByMediaViewer: Bool {
        var presented = presentedViewController
        while let current = presented {
            if let viewer = current as? MediaViewerController { return !viewer.isBeingDismissed }
            presented = current.presentedViewController
        }
        return false
    }

    /// 閉じるときは、タップした行のサムネイルへ戻す。同じ投稿とそのブーストが並んでいると、同じ添付ファイルのサムネイルが複数あるため。
    /// 開いている間にその行が再利用されたら、表示中の別の行から探す。
    /// - Parameter status: 添付ファイルの投稿。共有や保存の失敗を「最近の失敗」に残すときに添える。
    func openMedia(_ attachments: [MediaAttachment], at index: Int, of status: Status, from grid: MediaGridView) {
        openMedia(attachments, at: index, subject: OperationStatus.Subject(status)) { [weak self, weak grid] attachmentID in
            grid?.tile(for: attachmentID) ?? self?.visibleMediaTile(for: attachmentID)
        }
    }

    /// - Parameters:
    ///   - subject: 添付ファイルの投稿。プロフィールの画像ならnil。
    ///   - sourceTile: 開閉の起点にするビューを返す。見つからなければnilを返し、画像を動かさずに薄くして開閉する。
    func openMedia(_ attachments: [MediaAttachment], at index: Int, subject: OperationStatus.Subject?, sourceTile: @escaping @MainActor (MediaAttachment.ID) -> (any MediaViewerSource)?) {
        UserAction.openViewer(count: attachments.count, index: index).record()
        SciaLog.logger(category: "media").info("open viewer count=\(attachments.count, privacy: .public) index=\(index, privacy: .public)")
        let timing = MediaViewerController.Timing(tuning: tuning)
        let dragToDismiss = TuningCatalog.dragToDismiss(in: tuning)
        if MediaWindow.isAvailable {
            let request = MediaWindow.Request(
                attachments: attachments,
                startIndex: index,
                store: mediaImages,
                dragToDismiss: dragToDismiss,
                timing: timing,
                transfers: mediaTransfers,
                subject: subject
            )
            MediaWindow.open(request, from: view.window?.windowScene)
            return
        }
        MediaViewerController.present(
            attachments: attachments,
            startIndex: index,
            store: mediaImages,
            dragToDismiss: dragToDismiss,
            timing: timing,
            // アプリ内のSafariのシートを出していれば、その上に重ねる。
            from: frontmostPresented,
            transfers: mediaTransfers,
            subject: subject,
            sourceTile: sourceTile,
            onShowOperationStatus: onShowOperationStatus,
            // 一覧は残したままなので表示し直しの通知が来ない。開いている間に届いた新着を、閉じたところで報告する。
            onDismiss: { [weak self] in self?.reportVisibleItems() }
        )
    }

    /// 添付ファイルのサムネイルを、表示中のセルから探す。開いている間にセルが再利用されても、閉じるときに今の位置を探せるようにする。
    private func visibleMediaTile(for attachmentID: MediaAttachment.ID) -> MediaTileView? {
        for cell in collectionView.visibleCells {
            let grid = (cell.contentView as? PostContentView)?.mediaGrid ?? (cell.contentView as? NotificationContentView)?.mediaGrid
            if let tile = grid?.tile(for: attachmentID) {
                return tile
            }
        }
        return nil
    }
}
