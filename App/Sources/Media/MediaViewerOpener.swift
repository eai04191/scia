import os
import SciaCore
import UIKit

/// 添付ファイルのビューアを、今のチューニングで開く。一覧と編集履歴の画面で同じ開き方にする。
/// Macでは別のウィンドウで、iPhoneでは同じウィンドウの全画面に重ねて開く。
@MainActor
struct MediaViewerOpener {
    let store: MediaImageStore
    let tuning: TuningStore
    let transfers: MediaTransferCenter?
    /// アプリ全体のアプリ内通知。Macのビューアのウィンドウにもチップの列を重ねる。
    let notices: NoticeCenter?

    /// - Parameters:
    ///   - subject: 添付ファイルの投稿。共有や保存の失敗を「最近の失敗」に残すときに添える。プロフィールの画像ならnil。
    ///   - presenter: ビューアを重ねる画面。手前に重ねている画面（アプリ内のSafariのシートなど）があれば、その上に重ねる。
    ///   - sourceTile: 開閉の起点にするビューを返す。見つからなければnilを返し、画像を動かさずに薄くして開閉する。
    ///   - onDismiss: 同じウィンドウで開いたビューアを閉じ終えたときに呼ぶ。Macの別のウィンドウでは呼ばない。
    func open(
        _ attachments: [MediaAttachment],
        at index: Int,
        subject: OperationStatus.Subject?,
        from presenter: UIViewController,
        sourceTile: @escaping @MainActor (MediaAttachment.ID) -> (any MediaViewerSource)?,
        onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        UserAction.openViewer(count: attachments.count, index: index).record()
        SciaLog.logger(category: "media").info("open viewer count=\(attachments.count, privacy: .public) index=\(index, privacy: .public)")
        let timing = MediaViewerController.Timing(tuning: tuning)
        let dragToDismiss = TuningCatalog.dragToDismiss(in: tuning)
        if MediaWindow.isAvailable {
            let request = MediaWindow.Request(
                attachments: attachments,
                startIndex: index,
                store: store,
                dragToDismiss: dragToDismiss,
                timing: timing,
                transfers: transfers,
                notices: notices,
                subject: subject
            )
            MediaWindow.open(request, from: presenter.view.window?.windowScene)
            return
        }
        MediaViewerController.present(
            attachments: attachments,
            startIndex: index,
            store: store,
            dragToDismiss: dragToDismiss,
            timing: timing,
            from: presenter.frontmostPresented,
            transfers: transfers,
            subject: subject,
            sourceTile: sourceTile,
            onDismiss: onDismiss
        )
    }
}
