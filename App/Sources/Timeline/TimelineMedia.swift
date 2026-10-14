import os
import SciaCore
import UIKit

extension TimelineViewController {
    /// 本文の下に、`status`の添付ファイルを並べるセルの中身。`status`がnilなら本文だけにする。
    func statusContentConfiguration(list: UIListContentConfiguration, status: Status?) -> StatusContentConfiguration {
        var configuration = StatusContentConfiguration(list: list, mediaImages: mediaImages)
        guard let shown = status?.displayed, let media = mediaContent(for: shown) else { return configuration }
        configuration.media = media
        configuration.onSelectMedia = { [weak self] index, grid in
            self?.openMedia(shown.mediaAttachments, at: index, from: grid)
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
    func mediaContent(for status: Status) -> MediaGridView.Content? {
        guard !status.mediaAttachments.isEmpty else { return nil }
        let isSensitive = status.sensitive || !status.spoilerText.isEmpty
        return MediaGridView.Content(
            attachments: status.mediaAttachments,
            isCovered: isSensitive && !revealedMediaStatusIDs.contains(status.id),
            tallestAspectRatio: tuning.value(of: TuningCatalog.mediaTallestAspectRatio)
        )
    }

    /// 覆いを外す。同じ投稿をブーストした行と通知の行もまとめて描き直す。覆いと中身は同じ大きさのため、行の高さは変わらない。
    private func revealMedia(of statusID: Status.ID) {
        revealedMediaStatusIDs.insert(statusID)
        let ids = displayedItemIDs.filter { status(for: $0)?.displayed.id == statusID }
        reconfigure(Set(ids))
    }

    /// 閉じるときは、タップした行のサムネイルへ戻す。同じ投稿とそのブーストが並んでいると、同じ添付ファイルのサムネイルが複数あるため。
    /// 開いている間にその行が再利用されたら、表示中の別の行から探す。
    private func openMedia(_ attachments: [MediaAttachment], at index: Int, from grid: MediaGridView) {
        SciaLog.logger(category: "media").info("open viewer count=\(attachments.count, privacy: .public) index=\(index, privacy: .public)")
        MediaViewerController.present(attachments: attachments, startIndex: index, store: mediaImages, from: self) { [weak self, weak grid] attachmentID in
            grid?.tile(for: attachmentID) ?? self?.visibleMediaTile(for: attachmentID)
        }
    }

    /// 添付ファイルのサムネイルを、表示中のセルから探す。開いている間にセルが再利用されても、閉じるときに今の位置を探せるようにする。
    private func visibleMediaTile(for attachmentID: MediaAttachment.ID) -> UIView? {
        for cell in collectionView.visibleCells {
            if let tile = (cell.contentView as? StatusContentView)?.mediaGrid?.tile(for: attachmentID) {
                return tile
            }
        }
        return nil
    }
}

extension MastodonNotification.Kind {
    /// 対象の投稿の添付ファイルを並べる通知。お気に入りやブーストの通知は自分の投稿なので、本文だけにして行を低く保つ。
    var showsMedia: Bool {
        switch self {
        case .mention, .status, .quote: true
        case .reblog, .favourite, .poll, .update, .quotedUpdate, .follow, .followRequest, .other: false
        }
    }
}
