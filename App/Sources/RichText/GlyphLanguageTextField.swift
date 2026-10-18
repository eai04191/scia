import SciaCore
import UIKit

/// 注意書きのように、人が書いた言語の分からない文字を描く1行の入力欄。打った文字や置いた文字に、設定の字形の言語を付ける。
/// 言語を文字列に付ける理由は`GlyphLanguageTextView`と同じ。
/// UITextFieldは`defaultTextAttributes`の言語を文字に付けずに捨てる。前後の文字の言語も引き継がず、`typingAttributes`は書き始めたときと文字が入るたびに消す。
/// キーボードで打った文字はこの入力欄の`insertText`を通らないため、書き始めたときと文字が変わったときに、次に入る文字の言語を入れ直す。
/// 自動修正で置き換わった文字は`typingAttributes`を使わずに入るため、文字が変わったあとに言語のない文字が残っていれば、全体を付け直す。
class GlyphLanguageTextField: UITextField {
    private var language: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addAction(UIAction { [weak self] _ in self?.labelTyping() }, for: .editingDidBegin)
        addAction(UIAction { [weak self] _ in self?.labelEdits() }, for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 設定の字形の言語を付け始める。設定を選び直すと、書いてある文字も付け直す。
    func followGlyphLanguage(of settings: AppSettings) {
        withObservationTracking {
            language = settings.glyphLanguageIdentifier()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followGlyphLanguage(of: settings)
            }
        }
        relabel()
    }

    override var text: String? {
        get { super.text }
        set {
            guard let language, let newValue else {
                super.text = newValue
                return
            }
            var attributes = defaultTextAttributes
            attributes[.languageIdentifier] = language
            super.attributedText = NSAttributedString(string: newValue, attributes: attributes)
        }
    }

    /// 変換の途中は、変換中の文字を置き直すと変換が切れるため、確定するまで待つ。確定すると、また文字が変わったと知らされる。
    private func labelEdits() {
        labelTyping()
        guard let language, markedTextRange == nil, let current = attributedText else { return }
        var isLabeled = true
        current.enumerateAttribute(.languageIdentifier, in: NSRange(location: 0, length: current.length)) { value, _, stop in
            if value as? String != language {
                isLabeled = false
                stop.pointee = true
            }
        }
        if !isLabeled {
            relabel()
        }
    }

    private func labelTyping() {
        guard let language else { return }
        var attributes = typingAttributes ?? defaultTextAttributes
        attributes[.languageIdentifier] = language
        typingAttributes = attributes
    }

    /// 書いてある文字と次に入る文字を付け直す。文字列を置き直すと選択が末尾へ動くため、元の位置に戻す。
    /// 変換の途中なら、変換中の文字を確定してから付け直す。設定の画面は投稿欄の上に重なり、変換しながら選び直すことはまずないため、変換を続けられるようにはしない。
    private func relabel() {
        defer { labelTyping() }
        guard let language, let current = attributedText, current.length > 0 else { return }
        if markedTextRange != nil {
            unmarkText()
        }
        let selection = selectedTextRange.map { (offset(from: beginningOfDocument, to: $0.start), offset(from: $0.start, to: $0.end)) }
        let labeled = NSMutableAttributedString(attributedString: attributedText ?? current)
        labeled.addAttribute(.languageIdentifier, value: language, range: NSRange(location: 0, length: labeled.length))
        super.attributedText = labeled
        if let (location, length) = selection,
           let start = position(from: beginningOfDocument, offset: location),
           let end = position(from: start, offset: length) {
            selectedTextRange = textRange(from: start, to: end)
        }
    }
}
