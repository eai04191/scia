import os
import SciaCore
import UIKit

extension TimelineViewController {
    /// 通知の本文の下に、`status`の添付ファイルを並べるセルの中身。`status`がnilなら本文だけにする。
    private func statusContentConfiguration(list: UIListContentConfiguration, status: Status?) -> StatusContentConfiguration {
        var configuration = StatusContentConfiguration(list: list, mediaImages: mediaImages)
        guard let shown = status?.displayed, let media = mediaContent(for: shown) else { return configuration }
        configuration.media = media
        configuration.onSelectMedia = { [weak self] index, grid in
            self?.openMedia(media.attachments, at: index, from: grid)
        }
        configuration.onRevealMedia = { [weak self] in
            self?.revealMedia(of: shown.id)
        }
        return configuration
    }

    /// 通知のセルの中身。添付ファイルは、会話にあたる通知でだけ並べる。
    func statusContentConfiguration(list: UIListContentConfiguration, notification: MastodonNotification) -> StatusContentConfiguration {
        statusContentConfiguration(list: list, status: notification.type.showsMedia ? notification.status : nil)
    }

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
    var isCoveredByMediaViewer: Bool {
        guard let viewer = presentedViewController as? MediaViewerController else { return false }
        return !viewer.isBeingDismissed
    }

    /// 閉じるときは、タップした行のサムネイルへ戻す。同じ投稿とそのブーストが並んでいると、同じ添付ファイルのサムネイルが複数あるため。
    /// 開いている間にその行が再利用されたら、表示中の別の行から探す。
    func openMedia(_ attachments: [MediaAttachment], at index: Int, from grid: MediaGridView) {
        SciaLog.logger(category: "media").info("open viewer count=\(attachments.count, privacy: .public) index=\(index, privacy: .public)")
        MediaViewerController.present(
            attachments: attachments,
            startIndex: index,
            store: mediaImages,
            dragToDismiss: TuningCatalog.dragToDismiss(in: tuning),
            timing: MediaViewerController.Timing(
                openDuration: tuning.value(of: TuningCatalog.mediaOpenDuration),
                closeDuration: tuning.value(of: TuningCatalog.mediaCloseDuration),
                bounce: tuning.value(of: TuningCatalog.mediaTransitionBounce),
                drawsUnderBars: tuning.value(of: TuningCatalog.mediaCloseDrawsUnderBars),
                openHandoffEnd: tuning.value(of: TuningCatalog.mediaOpenHandoffEnd),
                openBarOverlapFadeStart: tuning.value(of: TuningCatalog.mediaOpenBarOverlapFadeStart),
                handoffStart: tuning.value(of: TuningCatalog.mediaCloseHandoffStart),
                barOverlapFadeEnd: tuning.value(of: TuningCatalog.mediaCloseBarOverlapFadeEnd),
                savedChipDuration: tuning.value(of: TuningCatalog.mediaSavedChipDuration),
                savedChipAtBottom: tuning.value(of: TuningCatalog.mediaSavedChipAtBottom)
            ),
            from: self,
            sourceTile: { [weak self, weak grid] attachmentID in
                grid?.tile(for: attachmentID) ?? self?.visibleMediaTile(for: attachmentID)
            },
            // 一覧は残したままなので表示し直しの通知が来ない。開いている間に届いた新着を、閉じたところで報告する。
            onDismiss: { [weak self] in self?.reportVisibleItems() }
        )
    }

    /// 添付ファイルのサムネイルを、表示中のセルから探す。開いている間にセルが再利用されても、閉じるときに今の位置を探せるようにする。
    private func visibleMediaTile(for attachmentID: MediaAttachment.ID) -> MediaTileView? {
        for cell in collectionView.visibleCells {
            let grid = (cell.contentView as? PostContentView)?.mediaGrid ?? (cell.contentView as? StatusContentView)?.mediaGrid
            if let tile = grid?.tile(for: attachmentID) {
                return tile
            }
        }
        return nil
    }
}

extension MastodonNotification.Kind {
    /// 会話にあたる通知。対象の投稿は相手が書いたもので、読む必要がある。お気に入りやブーストの通知は、自分の投稿の再掲になる。
    var isConversation: Bool {
        switch self {
        case .mention, .status, .quote: true
        case .reblog, .favourite, .poll, .update, .quotedUpdate, .follow, .followRequest, .other: false
        }
    }

    /// 対象の投稿の添付ファイルを並べる通知。自分の投稿の再掲になる通知は、本文だけにして行を低く保つ。
    var showsMedia: Bool { isConversation }
}
