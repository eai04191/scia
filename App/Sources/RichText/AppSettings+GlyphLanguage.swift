import Foundation
import SciaCore

extension AppSettings {
    /// 文字列の`.languageIdentifier`に付ける言語。漢字とかなの書体は、これで選ばれる。
    /// - Parameter textLanguage: 投稿に付いた言語。名前やアプリの文言など、言語の分からない文字ではnil。
    func glyphLanguageIdentifier(for textLanguage: String? = nil) -> String {
        glyphLanguage.identifier(textLanguage: textLanguage, preferredLanguages: Locale.preferredLanguages)
    }
}
