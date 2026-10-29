import CoreText
import SciaCore
import UIKit

/// Unicodeの絵文字を、設定の絵で描く書体にする。
/// twemojiでは、アプリに入れたtwemojiの書体（`Tools/build-twemoji-font.py`で作る）を代わりの書体の先頭に置く。
/// 標準の書体にない文字はAppleの絵文字より先にtwemojiで探されるため、「©」のように標準の書体で描ける文字は、絵文字にならずに文字のまま描かれる。
/// 文字列は変えないため、コピーや読み上げ、行の折り返しは、Appleの絵文字で描くときと変わらない。
@MainActor
enum EmojiFont {
    private static var cache: [UIFont: UIFont] = [:]
    /// twemojiを足した書体から、足す前の書体を引く。
    private static var originals: [UIFont: UIFont] = [:]

    private static let twemoji: UIFontDescriptor = {
        guard let url = Bundle.main.url(forResource: "Twemoji", withExtension: "ttf"),
              let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        else {
            fatalError("アプリにtwemojiの書体（Twemoji.ttf）が入っていない")
        }
        return descriptor as UIFontDescriptor
    }()

    static func font(_ font: UIFont, style: EmojiStyle) -> UIFont {
        switch style {
        case .system:
            return font
        case .twemoji:
            if let cached = cache[font] { return cached }
            let cascade = (font.fontDescriptor.object(forKey: .cascadeList) as? [UIFontDescriptor]) ?? []
            let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [twemoji] + cascade])
            let result = UIFont(descriptor: descriptor, size: font.pointSize)
            cache[font] = result
            originals[result] = font
            return result
        }
    }

    /// 測るのに使う絵文字。Appleの絵文字でもtwemojiでも、絵の枠いっぱいに描く。
    private static let measuredEmoji = "🟥"
    private static var glyphBounds: [UIFont: CGRect] = [:]
    private struct SizeKey: Hashable {
        let font: UIFont
        let glyphHeight: CGFloat
    }
    private static var sizes: [SizeKey: CGFloat] = [:]

    /// `font`の文字として描いた絵文字の、絵の高さ。
    /// Appleの絵文字は、小さい文字ほど文字の大きさより大きめに描く（17ptの文字で約20.5pt、25pt以上で文字と同じ）ため、文字の大きさからは求めない。
    static func glyphHeight(of font: UIFont) -> CGFloat {
        glyphBounds(of: font).height
    }

    /// `font`の文字として描いた絵文字の、絵の枠。ベースラインからの座標（上が正）。`font`の代わりの書体（Appleの絵文字かtwemoji）の字形の枠で測る。
    /// 絵文字の書体のascenderとdescenderは、描く絵より上下に余白を持つため、絵の位置と上下の範囲はこの枠で求める。
    static func glyphBounds(of font: UIFont) -> CGRect {
        if let cached = glyphBounds[font] { return cached }
        let bounds = measureGlyphBounds(of: font)
        glyphBounds[font] = bounds
        return bounds
    }

    private static func measureGlyphBounds(of font: UIFont) -> CGRect {
        let characters = Array(measuredEmoji.utf16)
        let fallback = CTFontCreateForString(font as CTFont, measuredEmoji as CFString, CFRange(location: 0, length: characters.count))
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(fallback, characters, &glyphs, characters.count), glyphs[0] != 0 else {
            fatalError("絵文字の書体に「\(measuredEmoji)」がない")
        }
        return CTFontGetBoundingRectsForGlyphs(fallback, .default, glyphs, nil, 1)
    }

    private struct ClusterKey: Hashable {
        let text: String
        let font: UIFont
    }
    /// 書記素クラスタは、異体字セレクターなどの並べ方で、見た目が同じでも別の文字列になり、種類に限りがない。
    /// 投稿から読んだ文字列を持ち続けないよう、キーの文字列の長さ（UTF-16の数）を重さにして上限を付ける。
    /// 上限は、よく使う絵文字を数千個持てる大きさ。捨てたものは、次に使うときに測り直すだけになる。
    private static var textBounds = CostLimitedCache<ClusterKey, CGRect>(totalCostLimit: 16 * 1024)

    /// `text`の絵文字（書記素クラスタ1つ）を`font`で描いたときの、絵の枠。ベースラインからの座標（上が正）。
    /// 大きさと位置を揃える基準は`glyphBounds(of:)`の枠だが、「⚕️」や「♀️」のように基準より下へ伸びる絵文字もあるため、
    /// 上下の部品とのあいだを測るときは、その絵文字自身の枠を使う。
    static func glyphBounds(of text: String, in font: UIFont) -> CGRect {
        let key = ClusterKey(text: text, font: font)
        if let cached = textBounds.value(forKey: key) { return cached }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        textBounds.setValue(bounds, forKey: key, cost: text.utf16.count)
        return bounds
    }

    /// 描いた絵文字の絵の高さが`height`になる、`font`の大きさ。絵の高さは文字の大きさに比例しないため、二分探索で求める。
    static func pointSize(of font: UIFont, drawingGlyphsOfHeight height: CGFloat) -> CGFloat {
        let key = SizeKey(font: font, glyphHeight: height)
        if let cached = sizes[key] { return cached }
        // 探す途中の大きさは、ほかで使わないので覚えない。
        var low: CGFloat = 0
        var high = height
        while measureGlyphBounds(of: font.withSize(high)).height < height {
            low = high
            high *= 2
        }
        for _ in 0..<30 {
            let middle = (low + high) / 2
            if measureGlyphBounds(of: font.withSize(middle)).height < height {
                low = middle
            } else {
                high = middle
            }
        }
        sizes[key] = high
        return high
    }

    /// twemojiで描くと文字の形を失う書記素クラスタを、twemojiを足す前の書体に戻す。
    /// - U+FE0E（文字で描く指定）が付いた文字。twemojiはU+FE0Eを区別せず、「☺︎」も絵文字の絵で描くため
    /// - 数字、「#」、「*」にU+FE0Fだけが付き、U+20E3が続かない並び。twemojiはキーキャップの合字の部品として、これらの文字を空の字形で持つため、
    ///   合字にならないと、文字が消える
    static func restoreTextPresentation(in string: NSMutableAttributedString) {
        let text = string.string as NSString
        // 本文を並べるたびに通るため、すべてのクラスタを見ずに、異体字セレクターのあるクラスタだけを見る。
        var location = 0
        while location < text.length {
            let selector = text.rangeOfCharacter(from: variationSelectors, options: [], range: NSRange(location: location, length: text.length - location))
            guard selector.location != NSNotFound else { return }
            let cluster = text.rangeOfComposedCharacterSequence(at: selector.location)
            location = NSMaxRange(cluster)
            guard needsTextFont(text.substring(with: cluster)),
                  let font = string.attribute(.font, at: cluster.location, effectiveRange: nil) as? UIFont,
                  let original = originals[font]
            else { continue }
            string.addAttribute(.font, value: original, range: cluster)
        }
    }

    private static let variationSelectors = CharacterSet(charactersIn: "\u{FE0E}\u{FE0F}")

    private static func needsTextFont(_ cluster: String) -> Bool {
        let scalars = cluster.unicodeScalars
        if scalars.contains("\u{FE0E}") { return true }
        guard let first = scalars.first, "0123456789#*".unicodeScalars.contains(first) else { return false }
        return scalars.contains("\u{FE0F}") && !scalars.contains("\u{20E3}")
    }
}
