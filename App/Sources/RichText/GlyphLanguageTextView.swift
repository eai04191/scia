import SciaCore
import UIKit

/// 代替テキストや投稿欄のように、人が書いた言語の分からない文字を描く入力欄。打った文字や置いた文字に、設定の字形の言語を付ける。
/// 漢字とかなの書体を言語から選ばせるため、標準の書体にない記号は、後ろの漢字やかなとランを分ける（`separateFallbackSymbols`）。
/// ビューの`typesettingLanguage`でも書体を選ぶ言語を渡せるが、UIKitは言語の部分しか保たず、繁体字を選んでも簡体字の書体になるため、文字列に付ける。
class GlyphLanguageTextView: UITextView, NSTextStorageDelegate {
    private var settings: AppSettings?

    /// 設定の字形の言語を付け始める。設定を選び直すと、書いてある文字も付け直す。
    func followGlyphLanguage(of settings: AppSettings) {
        self.settings = settings
        textStorage.delegate = self
        withObservationTracking {
            let language = settings.glyphLanguageIdentifier()
            textStorage.addAttribute(.languageIdentifier, value: language, range: NSRange(location: 0, length: textStorage.length))
            textStorage.separateFallbackSymbols(in: NSRange(location: 0, length: textStorage.length))
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followGlyphLanguage(of: settings)
            }
        }
    }

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
