#if DEBUG
import SciaCore
import UIKit

/// 投稿欄の添付のサムネイル（`ComposeAttachmentStrip`）の状態。
enum AttachmentStripCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "種類と代替テキスト（画像、ALTあり、GIF、動画、ALTありの動画）") {
                strip([
                    item(.image, color: .systemBlue),
                    item(.image, color: .systemGreen, description: "代替テキスト"),
                    item(.gifv, color: .systemIndigo),
                    item(.video, color: .systemTeal),
                    item(.video, color: .systemOrange, description: "代替テキスト"),
                ])
            },
            CatalogState(title: "アップロード中（0%、40%、100%、読み込み前）") {
                strip([
                    item(.image, color: .systemBlue, status: .uploading),
                    item(.image, color: .systemGreen, status: .uploading, progress: 0.4),
                    item(.video, color: .systemTeal, status: .uploading, progress: 1),
                    item(nil, color: .clear, status: .uploading),
                ])
            },
            CatalogState(title: "サーバーで処理中（画像、動画）") {
                strip([
                    item(.image, color: .systemBlue, status: .processing),
                    item(.video, color: .systemTeal, status: .processing),
                ])
            },
            CatalogState(title: "代替テキストを送信中（画像、GIF）") {
                strip([
                    item(.image, color: .systemGreen, description: "代替テキスト", status: .sendingDescription),
                    item(.gifv, color: .systemIndigo, description: "代替テキスト", status: .sendingDescription),
                ])
            },
            CatalogState(title: "アップロードできませんでした（画像、動画）") {
                strip([
                    item(.image, color: .systemBlue, status: .failed),
                    item(.video, color: .systemTeal, status: .failed),
                ])
            },
            CatalogState(title: "代替テキストを送信できませんでした（画像、GIF）") {
                strip([
                    item(.image, color: .systemGreen, description: "代替テキスト", status: .descriptionFailed),
                    item(.gifv, color: .systemIndigo, description: "代替テキスト", status: .descriptionFailed),
                ])
            },
            CatalogState(title: "閲覧注意（画像、ALTあり、GIF、動画、アップロード中、失敗）") {
                strip([
                    item(.image, color: .systemBlue, isSensitive: true),
                    item(.image, color: .systemGreen, description: "代替テキスト", isSensitive: true),
                    item(.gifv, color: .systemIndigo, isSensitive: true),
                    item(.video, color: .systemTeal, isSensitive: true),
                    item(.image, color: .systemOrange, status: .uploading, isSensitive: true),
                    item(.image, color: .systemPink, status: .failed, isSensitive: true),
                ])
            },
            CatalogState(title: "幅に収まらず横にスクロールする（8枚）") {
                strip((1...8).map { index in
                    item(.image, color: index.isMultiple(of: 2) ? .systemPink : .systemPurple, label: "\(index)", description: index.isMultiple(of: 3) ? "代替テキスト" : "")
                })
            },
        ]
    }

    /// 並べ替えも試せるよう、移した結果をその列の中だけで描き直す。
    @MainActor
    private static func strip(_ items: [ComposeAttachmentStrip.Item]) -> UIView {
        let strip = ComposeAttachmentStrip()
        var items = items
        strip.update(items)
        strip.onMove = { [weak strip] id, index in
            guard let from = items.firstIndex(where: { $0.attachment.id == id }) else { return }
            let moved = items.remove(at: from)
            items.insert(moved, at: min(max(index, 0), items.count))
            strip?.update(items)
        }
        return strip
    }

    /// - Parameters:
    ///   - kind: nilなら、端末からまだ読み込んでいない添付にする。サムネイルもない。
    ///   - label: サムネイルの中央に描く文字。並べ替えを試す列で見分けるために付ける。ほかの列では、動画の再生の印と重ならないよう付けない。
    private static func item(
        _ kind: MediaAttachment.Kind?,
        color: UIColor,
        label: String = "",
        description: String = "",
        status: ComposeAttachmentStatus = .ready,
        progress: Double = 0,
        isSensitive: Bool = false
    ) -> ComposeAttachmentStrip.Item {
        let id = UUID()
        let state: DraftAttachment.State = switch status {
        case .uploading: .uploading
        case .processing: .processing(serverID: id.uuidString)
        case .failed: .failed(serverID: nil)
        case .ready, .sendingDescription, .descriptionFailed:
            .uploaded(MediaAttachment(id: id.uuidString, type: kind ?? .image, url: nil, previewUrl: nil, description: description))
        }
        let local = LocalMedia(
            assetIdentifier: id.uuidString,
            load: { _ in throw LocalMediaError.loadFailed },
            file: kind.map { LocalMediaFile(url: URL(filePath: "/dev/null"), mimeType: "", kind: $0) },
            thumbnail: kind.map { _ in DummyMedia.image(size: CGSize(width: 192, height: 192), color: color, label: label) }
        )
        return ComposeAttachmentStrip.Item(attachment: DraftAttachment(id: id, state: state, description: description), local: local, status: status, progress: status == .uploading ? progress : nil, isSensitive: isSensitive)
    }
}
#endif
