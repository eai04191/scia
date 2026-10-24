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
        return TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
    }

    private func status(_ content: String, language: String?, spoiler: String = "") -> Status {
        Status(id: "1", createdAt: Date(timeIntervalSince1970: 0), account: account, content: "<p>\(content)</p>", spoilerText: spoiler, language: language, url: nil)
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

    /// 標準の書体にない文字のあとのかなも、ヒラギノで描く。
    /// 「𝕏」を描ける書体はSTIXしかなく、STIXは「の」も持つ。標準の書体にない文字が続く間、システムは先に使った書体を先に試すため、
    /// 「𝕏」と、かなや漢字が続く文では、離れた「の」までSTIXで描かれていた。韓国語の書体もかなを持つため、韓国語のすぐあとのかなも同じだった。
    @Test(arguments: ["𝕏の", "𝕏あいうの", "𝕏。の", "あ𝕏の", "𝕏🦐の", "⨁の", "한국어の"])
    func kanaAfterFallbackSymbolUsesJapaneseFont(_ content: String) throws {
        let configuration = try controller(glyphLanguage: .japanese).contentConfiguration(for: status(content, language: "ja"), base: .cell())

        #expect(isJapanese(fontNames(of: configuration.body)), "\(fontNames(of: configuration.body))")
    }

    /// 標準の書体にない記号のない投稿では、属性のランを分けない。
    /// ランが分かれると、分かれたランごとにシステムが書体を探し直す。漢字とかなのランを英字と分けたときは、iOSのシミュレーターで並べる時間が約3倍になった。
    /// 絵文字の書体はかなを持たないため、絵文字のあとのかなでも分けない。
    @Test func plainBodyKeepsOneAttributeRun() throws {
        let body = try controller(glyphLanguage: .japanese).contentConfiguration(for: status("今日はMastodonを試した🦐の話。한국어 も", language: "ja"), base: .cell()).body
        var runs = 0
        body.enumerateAttributes(in: NSRange(location: 0, length: body.length)) { _, _, _ in runs += 1 }

        #expect(runs == 1)
    }

    /// 記号の印でランを分けても、異体字セレクターで選んだ見た目は変えない。
    /// セレクターの手前でランを分けると、「葛󠄀」は選んだ字形でなくなっていた。macOSでは、「㊗️」「〰️」もカラー絵文字でなくヒラギノの記号になる。
    @Test(arguments: ["㊗️", "〰️", "葛\u{E0100}"])
    func variationSequenceKeepsItsGlyph(_ sequence: String) throws {
        let body = try controller(glyphLanguage: .japanese).contentConfiguration(for: status("𝕏\(sequence)b", language: "ja"), base: .cell()).body
        let plain = NSMutableAttributedString(attributedString: body)
        plain.removeAttribute(.fallbackSymbol, range: NSRange(location: 0, length: plain.length))

        #expect(glyphs(of: body) == glyphs(of: plain), "\(glyphs(of: plain))")
    }

    /// 文字列を1行に並べたときの、書体の名前と字形の番号。
    private func glyphs(of string: NSAttributedString) -> [String] {
        let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(string)) as? [CTRun] ?? []
        return runs.flatMap { run -> [String] in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            // swiftlint:disable:next force_cast
            let name = attributes[kCTFontAttributeName].map { CTFontCopyPostScriptName($0 as! CTFont) as String } ?? ""
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            return glyphs.map { "\(name)#\($0)" }
        }
    }

    /// 名前と注意書きも、ヒラギノで描く。
    @Test func nameAndSpoilerUseJapaneseFont() throws {
        let configuration = try controller(glyphLanguage: .japanese).contentConfiguration(for: status("本文", language: nil, spoiler: "見る前に"), base: .cell())

        #expect(isJapanese(fontNames(of: configuration.nameParts[0])), "\(fontNames(of: configuration.nameParts[0]))")
        let spoiler = try #require(configuration.spoiler)
        #expect(isJapanese(fontNames(of: spoiler.text)), "\(fontNames(of: spoiler.text))")
    }

    /// 「本文を表示」や通知の言い回し、プロフィールの件数の名前のようなアプリの文言は、設定の字形ではなく、ウィンドウに付けたアプリの言語で描く。
    /// 字形の設定で中国語を選んでも、文字列には言語を付けない。
    @Test func appTextHasNoGlyphLanguage() throws {
        let controller = try controller(glyphLanguage: .simplifiedChinese)
        let toggle = SpoilerView.toggleText(isCollapsed: true, kind: .contentWarning, font: .preferredFont(forTextStyle: .footnote))
        #expect(languages(in: toggle, of: "本文を表示") == [nil])

        let follow = MastodonNotification(id: "1", type: .follow, createdAt: Date(timeIntervalSince1970: 0), account: account)
        let header = try #require(controller.contentConfiguration(for: follow, base: .cell()) as? NotificationContentConfiguration).header
        #expect(languages(in: header, of: "日本語の名前") == ["zh-Hans"])
        #expect(languages(in: header, of: "にフォローされました") == [nil])

        let mention = MastodonNotification(id: "2", type: .mention, createdAt: Date(timeIntervalSince1970: 0), account: account, status: status("本文", language: nil))
        let context = try #require((controller.contentConfiguration(for: mention, base: .cell()) as? PostContentConfiguration)?.context?.text)
        #expect(languages(in: context, of: "日本語の名前") == ["zh-Hans"])
        #expect(languages(in: context, of: "からのメンション") == [nil])

        let counts = ProfileHeaderView.countsText(of: account)
        #expect(languages(in: counts, of: "フォロワー") == [nil])
    }

    /// 文字列のうち、`part`の範囲に付いている言語。
    private func languages(in string: NSAttributedString, of part: String) -> Set<String?> {
        let range = (string.string as NSString).range(of: part)
        guard range.location != NSNotFound else { return [] }
        var result = Set<String?>()
        string.enumerateAttribute(.languageIdentifier, in: range) { value, _, _ in result.insert(value as? String) }
        return result
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
