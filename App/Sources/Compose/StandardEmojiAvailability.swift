import CoreText
import SciaCore
import UIKit

/// 端末で描けるUnicodeの絵文字だけを、絵文字のシートに並べる。
///
/// アプリに入れた一覧（`StandardEmojiCatalog`）は、twemojiの書体と同じUnicodeの版で作っている。OSの絵文字で描く設定では、
/// 端末のiOSがまだ対応していない新しい絵文字が、豆腐（□）やばらばらの部品で描かれるため除く。
/// 描けるかは、OSの絵文字の書体で並べたとき、その書体の1つの字形になるかで見る。ZWJでつないだ新しい絵文字は、部品のそれぞれは描けるので、字形の数で見分ける。
/// 1つのコードポイントの新しい絵文字は、CoreTextがLastResortの書体の代わりの字形1つで描くので、描いた書体でも見分ける。
/// 古い版の絵文字はどのiOSでも描けるので、比べるのは新しい版だけにする。
@MainActor
enum StandardEmojiAvailability {
    /// これより前の版は、比べずに描けるとみなす。iOS 18で対応した版。
    private static let checkedFromVersion = 16.0
    private static var systemGroups: [StandardEmojiGroup]?

    static func groups(for style: EmojiStyle) -> [StandardEmojiGroup] {
        switch style {
        case .twemoji:
            return StandardEmojiCatalog.groups
        case .system:
            if let systemGroups { return systemGroups }
            let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
            let groups = StandardEmojiCatalog.groups.map { group in
                StandardEmojiGroup(title: group.title, emojis: group.emojis.filter { emoji in
                    (Double(emoji.version) ?? 0) < checkedFromVersion || isSingleGlyph(emoji.emoji, font: font)
                })
            }
            systemGroups = groups
            return groups
        }
    }

    private static func isSingleGlyph(_ emoji: String, font: CTFont) -> Bool {
        let string = NSAttributedString(string: emoji, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(string)
        guard CTLineGetGlyphCount(line) == 1, let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first,
              let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as? UIFont,
              runFont.fontName == CTFontCopyPostScriptName(font) as String
        else { return false }
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        return glyph != 0
    }
}
