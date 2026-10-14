import LinkPresentation
import UIKit

/// 共有シートに渡す、添付ファイルの元のファイル。写真への保存では使わず、`PhotoLibrarySaver`にファイルを直接渡す。
///
/// 画像の保存やコピーで縮めて展開した画像を渡さないよう、元のファイルをそのまま渡す。
/// ファイルだけを渡すと共有シートの見出しのプレビューが仮のアイコンになるため、描いている画像（動画は再生しているコマ）をプレビューとして添える。
final class MediaShareSheetItem: NSObject, UIActivityItemSource {
    /// 元のファイルの写し。拡張子は中身の形式に合わせてある。
    private let file: URL
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
