import Foundation

/// 漢字とかなを、どの言語の字形で描くか。
/// 文字列に言語がないと、システムは端末の言語の一覧から書体を選ぶ。一覧に日本語・中国語・韓国語がない英語の設定などでは、
/// 日本語の文も中国語の書体（簡体字の字形）で描かれるため、文字列に言語を付けて選ばせる。
public enum GlyphLanguage: String, CaseIterable, Sendable {
    /// 端末の言語の一覧で最初に出てくる、日本語・中国語・韓国語に従う。どれもなければ日本語にする。アプリの文言が日本語のため。
    case automatic
    case japanese
    case simplifiedChinese
    case traditionalChinese
    case korean

    /// 文字列に付ける言語の識別子。
    /// - Parameters:
    ///   - textLanguage: 投稿に付いた言語。日本語・中国語・韓国語なら、この設定より優先する。
    ///     英語などのそれ以外の言語は使わない。Mastodonの投稿の言語はWebのブラウザの言語が既定になるため、日本語の投稿に英語が付いていることが多い。
    ///   - preferredLanguages: 端末の言語の一覧。`automatic`で使う。
    public func identifier(textLanguage: String?, preferredLanguages: [String]) -> String {
        if let textLanguage, let identifier = Self.cjkIdentifier(textLanguage) {
            return identifier
        }
        return switch self {
        case .automatic: preferredLanguages.lazy.compactMap(Self.cjkIdentifier).first ?? Self.japanese.fixedIdentifier
        case .japanese, .simplifiedChinese, .traditionalChinese, .korean: fixedIdentifier
        }
    }

    private var fixedIdentifier: String {
        switch self {
        case .automatic, .japanese: "ja"
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        case .korean: "ko"
        }
    }

    /// 漢字を使う言語なら、字形の決まる識別子にする。「zh」は簡体字、「zh-TW」や「yue」は繁体字のように、文字体系から決める。
    private static func cjkIdentifier(_ identifier: String) -> String? {
        let maximal = Locale.Language(identifier: Locale.Language(identifier: identifier).maximalIdentifier)
        return switch maximal.script?.identifier {
        case "Jpan": "ja"
        case "Hans": "zh-Hans"
        case "Hant": "zh-Hant"
        case "Kore": "ko"
        default: nil
        }
    }
}
