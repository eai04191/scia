import SciaCore
import UIKit

/// 代替テキストや投稿欄のように、人が書いた言語の分からない文字を描く入力欄。打った文字や置いた文字に、設定の字形の言語を付ける。
/// 漢字とかなの書体を言語から選ばせるため、標準の書体にない記号は、後ろの漢字やかなとランを分ける（`separateFallbackSymbols`）。
/// ビューの`typesettingLanguage`でも書体を選ぶ言語を渡せるが、UIKitは言語の部分しか保たず、繁体字を選んでも簡体字の書体になるため、文字列に付ける。
class GlyphLanguageTextView: UITextView, NSTextStorageDelegate {
    private var settings: AppSettings?

    /// ペーストした文字を、コピーしたとおりに入れる。UIKitのスマート挿入は、英字の後ろに「─」を貼ると間に空白を足していた。
    /// 人が書いてサーバーに送る文字の入力欄は、どれもこの型か`GlyphLanguageTextField`なので、ここで切る。
    override var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set {}
    }

    /// 設定の字形の言語を付け始める。設定を選び直すと、書いてある文字も付け直す。
    func followGlyphLanguage(of settings: AppSettings) {
        self.settings = settings
        textStorage.delegate = self
        withObservationTracking {
            let language = settings.glyphLanguageIdentifier()
            textStorage.addAttribute(.languageIdentifier, value: language, range: NSRange(location: 0, length: textStorage.length))
            textStorage.separateFallbackSymbols(in: NSRange(location: 0, length: textStorage.length))
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                self?.followGlyphLanguage(of: settings)
            }
        }
    }

    /// `lines`行の文字を並べたときの、上下の余白を含めた入力欄の高さ。
    /// 日本語の字形では、TextKitが行を書体の`lineHeight`より高く並べるため、書体の値から計算すると、上限の行数ちょうどの本文が収まらず中でスクロールする。
    /// 同じ書体、字形の言語、余白で文字を並べて測る。
    func height(ofLines lines: Int) -> CGFloat {
        let key = LineHeightKey(
            lines: lines,
            font: font ?? .preferredFont(forTextStyle: .body),
            language: settings?.glyphLanguageIdentifier(),
            insetTop: textContainerInset.top,
            insetBottom: textContainerInset.bottom
        )
        if let height = measuredLineHeights[key] {
            return height
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: key.font]
        if let language = key.language {
            attributes[.languageIdentifier] = language
        }
        lineMeasurer.textContainerInset = textContainerInset
        lineMeasurer.textContainer.lineFragmentPadding = 0
        lineMeasurer.attributedText = NSAttributedString(string: Array(repeating: "A", count: max(lines, 1)).joined(separator: "\n"), attributes: attributes)
        let height = lineMeasurer.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).height
        measuredLineHeights[key] = height
        return height
    }

    private struct LineHeightKey: Hashable {
        let lines: Int
        let font: UIFont
        let language: String?
        let insetTop: CGFloat
        let insetBottom: CGFloat
    }

    private lazy var lineMeasurer = UITextView()
    private var measuredLineHeights: [LineHeightKey: CGFloat] = [:]

    // 入力欄の文字列は、入力欄と同じメインスレッドで書き換わる。
    nonisolated func textStorage(_: NSTextStorage, willProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard let settings else { return }
            self.textStorage.addAttribute(.languageIdentifier, value: settings.glyphLanguageIdentifier(), range: editedRange)
            self.textStorage.separateFallbackSymbols(in: editedRange)
        }
    }
}
