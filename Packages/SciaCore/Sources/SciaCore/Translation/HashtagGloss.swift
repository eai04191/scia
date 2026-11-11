import Foundation

/// ハッシュタグの後ろに併記する訳。決まりはdocs/auto-translation.mdの「本文の扱い」にある。
enum HashtagGloss {
    /// Translationフレームワークへ渡す文字。`#`を除いた名前を、大文字の境目と`_`で語に分ける。訳す文字がなければnil。
    static func words(of name: String) -> String? {
        guard name.contains(where: \.isLetter) else { return nil }
        return name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"(?<=[\p{Ll}\d])(?=\p{Lu})|(?<=\p{Lu})(?=\p{Lu}\p{Ll})"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 併記する訳。`translated`が元の名前と同じ文字なら、併記しないのでnil。
    static func gloss(translated: String, name: String) -> String? {
        let gloss = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = comparisonKey(gloss)
        guard !key.isEmpty, key != comparisonKey(name) else { return nil }
        return gloss
    }

    /// ハッシュタグの後ろに足す文字。
    static func suffix(_ gloss: String, target: String) -> String {
        switch Locale.Language(identifier: target).languageCode?.identifier {
        case "ja", "zh": "（\(gloss)）"
        default: " (\(gloss))"
        }
    }

    private static func comparisonKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
