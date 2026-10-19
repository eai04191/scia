import SwiftUI
import UIKit

/// インスタンスのアドレスの入力欄。打ち直しやすいよう、編集中は標準の消去ボタンを出す。
/// SwiftUIのTextFieldには消去ボタンを出す方法がないため、UITextFieldを使う。
struct InstanceTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onSubmit: @MainActor () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
        field.textContentType = .URL
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        // 候補を選んだときのように、入力欄の外から変わったときだけ入れ直す。打っている途中に入れ直すと、カーソルが末尾へ飛ぶため。
        if field.text != text {
            field.text = text
        }
        field.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        let width = proposal.width ?? field.intrinsicContentSize.width
        return CGSize(width: width, height: field.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onSubmit: @MainActor () -> Void

        init(text: Binding<String>, onSubmit: @escaping @MainActor () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        @objc func editingChanged(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            onSubmit()
            return false
        }
    }
}
