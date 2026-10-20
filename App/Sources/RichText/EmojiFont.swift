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
