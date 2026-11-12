import SciaCore
import SwiftUI
import UIKit

/// SwiftUIの画面に置く、人が書いてサーバーに送る文字の1行の入力欄。
/// SwiftUIの`TextField`はスマート挿入を切れないため、`GlyphLanguageTextField`を使う。
struct GlyphLanguageField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var settings: AppSettings = AppDependencies.settings
    /// 自動修正、スペルチェック、文頭の大文字。フィルターのキーワードのように、打ったとおりに入れたい欄ではfalse。
    var corrects = true

    func makeUIView(context: Context) -> GlyphLanguageTextField {
        let field = GlyphLanguageTextField()
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        if !corrects {
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
        }
        field.followGlyphLanguage(of: settings)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: GlyphLanguageTextField, context: Context) {
        context.coordinator.text = $text
        // 入力欄の外から変わったときだけ入れ直す。打っている途中に入れ直すと、カーソルが末尾へ飛び、変換も切れるため。
        if field.text != text {
            field.text = text
        }
        field.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: GlyphLanguageTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? field.intrinsicContentSize.width
        return CGSize(width: width, height: field.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func editingChanged(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return false
        }
    }
}
