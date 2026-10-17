import Foundation
import Testing
@testable import SciaCore

struct GlyphLanguageTests {
    /// 投稿に日本語・中国語・韓国語の言語が付いていれば、設定にかかわらずその字形で描く。中国語は文字体系まで決める。
    @Test(arguments: [("ja", "ja"), ("zh", "zh-Hans"), ("zh-CN", "zh-Hans"), ("zh-TW", "zh-Hant"), ("zh-HK", "zh-Hant"), ("yue", "zh-Hant"), ("ko", "ko")])
    func cjkTextLanguageWins(_ textLanguage: String, _ expected: String) {
        for setting in GlyphLanguage.allCases {
            #expect(setting.identifier(textLanguage: textLanguage, preferredLanguages: ["en-US"]) == expected)
        }
    }

    /// 日本語の投稿にも英語が付いていることが多いため、漢字を使わない言語は無視して設定に従う。
    @Test(arguments: [nil, "en", "fr", ""] as [String?])
    func otherTextLanguageFollowsSetting(_ textLanguage: String?) {
        #expect(GlyphLanguage.japanese.identifier(textLanguage: textLanguage, preferredLanguages: ["zh-Hans-CN"]) == "ja")
        #expect(GlyphLanguage.simplifiedChinese.identifier(textLanguage: textLanguage, preferredLanguages: ["ja-JP"]) == "zh-Hans")
        #expect(GlyphLanguage.traditionalChinese.identifier(textLanguage: textLanguage, preferredLanguages: ["ja-JP"]) == "zh-Hant")
        #expect(GlyphLanguage.korean.identifier(textLanguage: textLanguage, preferredLanguages: ["ja-JP"]) == "ko")
    }

    /// 自動では、端末の言語の一覧で最初の日本語・中国語・韓国語に従い、どれもなければ日本語にする。
    @Test func automaticFollowsFirstCJKPreferredLanguage() {
        #expect(GlyphLanguage.automatic.identifier(textLanguage: nil, preferredLanguages: ["en-US"]) == "ja")
        #expect(GlyphLanguage.automatic.identifier(textLanguage: "en", preferredLanguages: []) == "ja")
        #expect(GlyphLanguage.automatic.identifier(textLanguage: nil, preferredLanguages: ["en-US", "zh-Hant-TW", "ja-JP"]) == "zh-Hant")
        #expect(GlyphLanguage.automatic.identifier(textLanguage: nil, preferredLanguages: ["fr-FR", "ko-KR"]) == "ko")
        #expect(GlyphLanguage.automatic.identifier(textLanguage: nil, preferredLanguages: ["ja-JP", "zh-Hans-CN"]) == "ja")
    }
}
