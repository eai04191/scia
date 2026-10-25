#if DEBUG
import UIKit

/// ビューアの下に出す説明（`CaptionView`）の状態。ビューアと同じく、画像の上の下端に置く。
enum CaptionCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "短い説明") { caption("縦長の画像（9:16）") },
            CatalogState(title: "1行に収まらない説明（末尾で切る）") {
                caption("正方形の画像。オレンジの地に白い格子が引かれ、中央に「3 正方形」と大きく書かれている。代替テキストが長いときに、1行で切れることを確かめるための文。")
            },
            CatalogState(title: "投稿欄から開いて、代替テキストがない") { caption("", isEditable: true) },
            CatalogState(title: "投稿欄から開いて、代替テキストがある") { caption("縦長の画像（9:16）", isEditable: true) },
            CatalogState(title: "コントラストを上げる設定で、代替テキストがない（「代替テキストを追加」を濃く）") {
                caption("", isEditable: true, contrast: .high)
            },
        ]
    }

    @MainActor
    /// - Parameter contrast: コントラストの設定。nilなら端末の設定に従う。
    private static func caption(_ text: String, isEditable: Bool = false, contrast: UIAccessibilityContrast? = nil) -> UIView {
        let caption = CaptionView()
        if let contrast {
            caption.traitOverrides.accessibilityContrast = contrast
        }
        caption.isEditable = isEditable
        caption.text = text
        return CatalogBackdrop.image(caption) { backdrop, _ in
            [
                caption.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 32),
                caption.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
                caption.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                caption.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                // ビューアでは文字の下端を安全領域に合わせる。カタログでは下に少しだけ余白を取る。
                caption.contentBottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -12),
            ]
        }
    }
}
#endif
