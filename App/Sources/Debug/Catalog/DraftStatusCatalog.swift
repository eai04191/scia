#if DEBUG
import UIKit

/// 投稿欄から開いたビューアの、アップロードや代替テキストの送信の状態（`DraftStatusButton`）。ガラスの効果を見られるよう、画像の上に置く。
enum DraftStatusCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "アップロード中") { button(.uploading) },
            CatalogState(title: "サーバーで処理中") { button(.processing) },
            CatalogState(title: "代替テキストを送信中") { button(.sendingDescription) },
            CatalogState(title: "アップロードできませんでした（押せる）") { button(.failed) },
            CatalogState(title: "代替テキストを送信できませんでした（押せる）") { button(.descriptionFailed) },
        ]
    }

    @MainActor
    private static func button(_ status: ComposeAttachmentStatus) -> UIView {
        let button = DraftStatusButton()
        button.apply(status)
        return CatalogBackdrop.image(button) { backdrop, button in
            [
                button.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 24),
                button.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -24),
                button.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
                // ビューアと同じく、左右に16ずつ空ける。
                button.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -32),
            ]
        }
    }
}
#endif
