import os
import SciaCore
import UIKit

/// Macで動かしているときに、投稿に添付するメディアを選ぶファイルの選択画面。
/// 写真のピッカー（`MediaPickerSheet`）の代わりに出す。
/// 選んだファイルは、ペーストしたファイルと同じく後ろに足す。
@MainActor
final class MediaFilePicker: NSObject {
    /// 選んだファイルを渡す。選ばずに閉じたときは呼ばない。
    var onPick: ([URL]) -> Void = { _ in }
    /// 選んだかどうかによらず、閉じたときに呼ぶ。
    var onDidClose: () -> Void = {}

    private let picker: UIDocumentPickerViewController
    private let logger = SciaLog.logger(category: "compose")

    override init() {
        // 選んだファイルのコピーを受け取る。元のファイルを直接読むと、読み終えるまでアクセスの許可を保たなければならないため。
        picker = UIDocumentPickerViewController(forOpeningContentTypes: LocalMediaLoader.mediaTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        super.init()
        picker.delegate = self
    }

    func present(from host: UIViewController) {
        host.present(picker, animated: true)
    }
}

extension MediaFilePicker: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        logger.info("media file picker: picked (count=\(urls.count))")
        onPick(urls)
        onDidClose()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        logger.info("media file picker: cancelled")
        onDidClose()
    }
}
