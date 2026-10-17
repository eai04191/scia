import CoreText
import Foundation
import SciaCore
import Testing
import UIKit
@testable import Scia

/// 文字列に言語がないと、システムは端末の言語の一覧から漢字とかなの書体を選ぶ。英語の設定では、日本語の文も中国語の書体で描かれていた。
/// 端末の言語の設定に左右されないことを確かめるため、英語の設定（`-testLanguage en`）でも通す。
@MainActor
struct GlyphLanguageTests {
    private let account = Account(id: "1", username: "alice", acct: "alice", displayName: "日本語の名前", avatar: nil)

    private func controller(glyphLanguage: GlyphLanguage) throws -> TimelineViewController {
        let defaults = try #require(UserDefaults(suiteName: "GlyphLanguageTests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.glyphLanguage = glyphLanguage
        return TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
    }

    private func status(_ content: String, language: String?, spoiler: String = "") -> Status {
        Status(id: "1", createdAt: .now, account: account, content: "<p>\(content)</p>", spoilerText: spoiler, language: language, url: nil)
    }

    /// 漢字とかなを描くときに選ばれた書体の名前。英字や記号、画像の置き場の文字は、どの言語でも同じ書体で描かれるため除く。
    private func fontNames(of string: NSAttributedString) -> Set<String> {
        let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(string)) as? [CTRun] ?? []
        return Set(runs.compactMap { run in
            let range = CTRunGetStringRange(run)
            let text = (string.string as NSString).substring(with: NSRange(location: range.location, length: range.length))
            guard text.unicodeScalars.contains(where: { (0x3000...0x9FFF).contains($0.value) }) else { return nil }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] else { return nil }
            // swiftlint:disable:next force_cast
            return CTFontCopyPostScriptName(font as! CTFont) as String
        })
    }

    private func isJapanese(_ names: Set<String>) -> Bool {
        !names.isEmpty && names.allSatisfy { $0.contains("HiraKaku") }
    }

    /// 日本語の投稿は、言語がなくても、英語が付いていても、ヒラギノで描く。
    /// 「自動」は端末の言語の一覧で決まり、テストを走らせる端末で結果が変わるため、日本語を選んで確かめる。「自動」の決め方はSciaCoreで確かめる。
    @Test(arguments: [nil, "ja", "en"] as [String?])
    func japaneseBodyUsesJapaneseFont(_ language: String?) throws {
        let configuration = try controller(glyphLanguage: .japanese).contentConfiguration(for: status("本文と画像のあいだを見る。", language: language), base: .cell())

        #expect(isJapanese(fontNames(of: configuration.body)), "\(fontNames(of: configuration.body))")
    }

    /// 名前と、注意書きと、注意書きの箱のアプリの文言も、ヒラギノで描く。
    @Test func nameAndSpoilerUseJapaneseFont() throws {
        let configuration = try controller(glyphLanguage: .japanese).contentConfiguration(for: status("本文", language: nil, spoiler: "見る前に"), base: .cell())

        #expect(isJapanese(fontNames(of: configuration.nameParts[0])), "\(fontNames(of: configuration.nameParts[0]))")
        let spoiler = try #require(configuration.spoiler)
        #expect(isJapanese(fontNames(of: spoiler.text)), "\(fontNames(of: spoiler.text))")
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        // ラベルの文字の大きさで描くため、文字列には書体が付いていない。ラベルと同じく、付いていない範囲に書体を足して測る。
        let toggle = NSMutableAttributedString(attributedString: SpoilerView.toggleText(isCollapsed: true, font: font, language: spoiler.toggleLanguage))
        toggle.addAttribute(.font, value: font, range: NSRange(location: 0, length: toggle.length))
        #expect(isJapanese(fontNames(of: toggle)), "\(fontNames(of: toggle))")
    }

    /// 中国語の投稿は、設定にかかわらず中国語の書体で描く。
    @Test(arguments: [("zh", "SC"), ("zh-TW", "TC")])
    func chineseBodyKeepsChineseFont(_ language: String, _ suffix: String) throws {
        let configuration = try controller(glyphLanguage: .japanese).contentConfiguration(for: status("直骨关门。", language: language), base: .cell())
        let names = fontNames(of: configuration.body)

        #expect(!names.contains { $0.contains("HiraKaku") }, "\(names)")
        #expect(names.contains { $0.contains("PingFang") && $0.contains(suffix) }, "\(names)")
    }

    /// 設定で中国語の字形を選ぶと、言語のない投稿もその書体で描く。
    @Test func settingChoosesFontForUnlabeledText() throws {
        let configuration = try controller(glyphLanguage: .simplifiedChinese).contentConfiguration(for: status("直骨", language: nil), base: .cell())
        let names = fontNames(of: configuration.body)

        #expect(names.contains { $0.contains("PingFang") && $0.contains("SC") }, "\(names)")
    }
}
