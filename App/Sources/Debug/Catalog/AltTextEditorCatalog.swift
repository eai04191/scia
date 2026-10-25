#if DEBUG
import UIKit

/// 代替テキストの入力欄（`AltTextEditorView`）の状態。ビューアと同じく、画像の上の下端に置く。
/// 残りの文字数は、上限を小さくして出す。実際の上限（1500文字）近くまで書くと、入力欄が最大の行数まで伸びて数を見比べにくいため。
enum AltTextEditorCatalog {
    @MainActor
    static func states() -> [CatalogState] {
        [
            CatalogState(title: "空（プレースホルダー）") { editor("") },
            CatalogState(title: "残りを出す前（上限1500文字に短い文）") { editor("オレンジの地に白い格子") },
            CatalogState(title: "残りを出す（上限30文字に8文字、残り22）") { editor("オレンジの地に白", limit: 30) },
            CatalogState(title: "ちょうど上限（上限30文字に30文字、残り0）") { editor(String(repeating: "あ", count: 30), limit: 30) },
            CatalogState(title: "上限超え（上限30文字に38文字、-8を赤）") { editor(String(repeating: "あ", count: 38), limit: 30) },
            CatalogState(title: "コントラストを上げる設定で、空（プレースホルダーを濃く）") { editor("", contrast: .high) },
            CatalogState(title: "コントラストを上げる設定で、残りを出す（数を濃く）") { editor("オレンジの地に白", limit: 30, contrast: .high) },
            CatalogState(title: "いちばん大きい文字で、残りを出す") { editor("オレンジの地に白", limit: 30, contentSize: .accessibilityExtraExtraExtraLarge) },
            CatalogState(title: "最大の行数を超えて、中でスクロールする") {
                editor(String(repeating: "代替テキストが長いときに、入力欄が最大の行数で止まり、中でスクロールすることを確かめる文。", count: 6))
            },
        ]
    }

    @MainActor
    /// - Parameters:
    ///   - contrast: コントラストの設定。nilなら端末の設定に従う。
    ///   - contentSize: 文字の大きさの設定。nilなら端末の設定に従う。
    private static func editor(_ text: String, limit: Int = 1500, contrast: UIAccessibilityContrast? = nil, contentSize: UIContentSizeCategory? = nil) -> UIView {
        let editor = AltTextEditorView()
        if let contrast {
            editor.traitOverrides.accessibilityContrast = contrast
        }
        if let contentSize {
            editor.traitOverrides.preferredContentSizeCategory = contentSize
        }
        editor.limit = limit
        editor.text = text
        return CatalogBackdrop.image(editor) { backdrop, editor in
            [
                editor.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 32),
                editor.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
                editor.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                editor.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            ]
        }
    }
}
#endif
