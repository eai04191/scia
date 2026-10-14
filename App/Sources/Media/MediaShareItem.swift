import LinkPresentation
import UIKit

/// 共有シートに渡す、添付ファイルの画像。
///
/// 保存やコピーで縮めて展開した画像を渡さないよう、元のファイルをそのまま渡す。
/// ファイルだけを渡すと共有シートの見出しのプレビューが仮のアイコンになるため、画像をプレビューとして添える。
final class MediaShareItem: NSObject, UIActivityItemSource {
    /// 元のファイル。拡張子は中身の形式に合わせてある。
    let file: URL
    private let preview: UIImage

    init(file: URL, preview: UIImage) {
        self.file = file
        self.preview = preview
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        file
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        file
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = file
        metadata.url = file
        metadata.imageProvider = NSItemProvider(object: preview)
        return metadata
    }
}
