import CoreText
import SciaCore
import UIKit

/// 端末で描けるUnicodeの絵文字だけを、絵文字のシートに並べる。
///
/// アプリに入れた絵文字のリスト（`StandardEmojiCatalog`）は、twemojiの書体と同じUnicodeの版で作っている。OSの絵文字で描く設定では、
/// 端末のiOSがまだ対応していない新しい絵文字が、豆腐（□）やばらばらの部品で描かれるため除く。
/// 描けるかは、OSの絵文字の書体で並べたとき、その書体の1つの字形になるかで見る。ZWJでつないだ新しい絵文字は、部品のそれぞれは描けるので、字形の数で見分ける。
/// 1つのコードポイントの新しい絵文字は、CoreTextがLastResortの書体の代わりの字形1つで描くので、描いた書体でも見分ける。
/// 古い版の絵文字はどのiOSでも描けるので、比べるのは新しい版だけにする。
@MainActor
enum StandardEmojiAvailability {
    /// これより前の版は、比べずに描けるとみなす。iOS 18で対応した版。
    private static let checkedFromVersion = 16.0
    private static var systemGroups: [StandardEmojiGroup]?

    private static var toned: (style: EmojiStyle, tone: EmojiSkinTone, groups: [StandardEmojiGroup])?

    /// `style`で描ける絵文字を、肌の色を変えられるものは`skinTone`の色にして並べたリスト。
    static func groups(for style: EmojiStyle, skinTone: EmojiSkinTone) -> [StandardEmojiGroup] {
        guard skinTone != .none else { return groups(for: style) }
        if let toned, toned.style == style, toned.tone == skinTone { return toned.groups }
        let groups = groups(for: style).withSkinTone(skinTone)
        toned = (style, skinTone, groups)
        return groups
    }

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
                }.map { emoji in
                    // 肌の色を付けた並びは、元の絵文字より後の版で足されたものがある（うさ耳の人やレスリングは17.0）。
                    // 端末が1つの絵にできない並びは選ばせない。2人の色の違う並びだけ描けないなら、2人同じ色だけを選ばせる。
                    guard let samples = emoji.skinToneSamples else { return emoji }
                    guard isSingleGlyph(samples.same, font: font) else { return emoji.removingSkinTones() }
                    guard let mixed = samples.mixed, !isSingleGlyph(mixed, font: font) else { return emoji }
                    return emoji.limitingSkinTonesToSameForBoth()
                })
            }
            systemGroups = groups
            return groups
        }
    }

    private static func isSingleGlyph(_ emoji: String, font: CTFont) -> Bool {
        let string = NSAttributedString(string: emoji, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(string)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1, let run = runs.first,
              let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as? UIFont,
              runFont.fontName == CTFontCopyPostScriptName(font) as String
        else { return false }
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
        guard count > 0, !glyphs.contains(0) else { return false }
        // 字形が複数でも、送り幅を持つものが1つなら、重ねて1つの絵に描かれる。
        // 2人の肌の色が違う並び（🫱🏻‍🫲🏼など）は、iPad miniのシミュレーター（iOS 27.2）では字形2つを重ねて描かれ、送り幅は片方が0だった。
        // 書体が1つの絵にできない並びは、字形ごとに送り幅を持って横に並ぶ。
        return advances.filter { $0.width > 0 }.count == 1
    }
}
