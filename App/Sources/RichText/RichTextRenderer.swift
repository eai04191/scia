import SciaCore
import UIKit

/// RichTextを、UILabelに渡せるNSAttributedStringにする。
@MainActor
struct RichTextRenderer {
    var font: UIFont
    var textColor: UIColor
    var secondaryColor: UIColor = .secondaryLabel
    var linkColor: UIColor = .tintColor
    var paragraphSpacing: CGFloat = 0
    let emojiImages: EmojiImageStore
    /// 文字列に付ける言語。付けないと、漢字とかなの書体が端末の言語の設定で決まり、英語の設定では日本語も中国語の書体で描かれる。
    let language: String

    /// 引用とリストの1段あたりの字下げ。
    private let indentPerLevel: CGFloat = 16

    func render(_ text: RichText) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in text.blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let start = result.length
            if let marker = block.listMarker {
                result.append(NSAttributedString(string: marker, attributes: attributes(style: [], block: block)))
            }
            for inline in block.inlines {
                result.append(render(inline, block: block))
            }
            result.addAttribute(.paragraphStyle, value: paragraphStyle(for: block), range: NSRange(location: start, length: result.length - start))
        }
        return result
    }

    /// 本文中のすべてのカスタム絵文字の、表示に使うURL。
    static func emojiURLs(in text: RichText) -> Set<URL> {
        Set(text.blocks.flatMap(\.inlines).compactMap { inline in
            if case .emoji(let emoji) = inline { emoji.staticUrl } else { nil }
        })
    }

    private func render(_ inline: RichText.Inline, block: RichText.Block) -> NSAttributedString {
        switch inline {
        case .text(let text, let style):
            return NSAttributedString(string: Self.lineSeparated(text), attributes: attributes(style: style, block: block))
        case .link(let text, let destination, let style):
            var attributes = attributes(style: style, block: block)
            attributes[.foregroundColor] = linkColor
            attributes[.linkDestination] = destination
            return NSAttributedString(string: Self.lineSeparated(text), attributes: attributes)
        case .emoji(let emoji):
            return render(emoji, block: block)
        case .lineBreak:
            // 段落を分けると段落間隔が入るため、段落の中の改行は行区切り文字にする。
            return NSAttributedString(string: "\u{2028}", attributes: attributes(style: [], block: block))
        }
    }

    private func render(_ emoji: CustomEmoji, block: RichText.Block) -> NSAttributedString {
        let font = font(for: [], block: block)
        if emojiImages.hasFailed(emoji.staticUrl) {
            return NSAttributedString(string: ":\(emoji.shortcode):", attributes: attributes(style: [], block: block))
        }
        let height = font.lineHeight
        let attachment = NSTextAttachment()
        if let image = emojiImages.image(for: emoji.staticUrl), image.size.height > 0 {
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: font.descender, width: height * image.size.width / image.size.height, height: height)
        } else {
            // 読み込み中は同じ高さの空白で場所を取っておく。
            attachment.image = Self.placeholder
            attachment.bounds = CGRect(x: 0, y: font.descender, width: height, height: height)
        }
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes(style: [], block: block), range: NSRange(location: 0, length: string.length))
        return string
    }

    /// コードブロックなどの文字に含まれる改行を、段落を分けない行区切り文字にする。
    private static func lineSeparated(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\u{2028}")
    }

    private static let placeholder = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    private func attributes(style: RichText.Style, block: RichText.Block) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: style, block: block),
            .foregroundColor: block.quoteLevel > 0 ? secondaryColor : textColor,
            .languageIdentifier: language,
        ]
        if style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private func font(for style: RichText.Style, block: RichText.Block) -> UIFont {
        if block.isCode || style.contains(.code) {
            let weight: UIFont.Weight = style.contains(.bold) ? .bold : .regular
            return UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: font.pointSize, weight: weight))
        }
        var traits = font.fontDescriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        guard traits != font.fontDescriptor.symbolicTraits,
              let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private func paragraphStyle(for block: RichText.Block) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = paragraphSpacing
        let indent = CGFloat(block.quoteLevel + max(0, block.listLevel - 1)) * indentPerLevel
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        if let marker = block.listMarker {
            // 折り返した行を、記号のあとの本文の位置に揃える。
            style.headIndent = indent + (marker as NSString).size(withAttributes: [.font: font]).width
        }
        return style
    }
}

extension NSAttributedString.Key {
    /// リンクの行き先（`RichText.LinkDestination`）。`.link`はUILabelが特別に扱い、再利用したラベルで前の内容の色のまま次の本文を描くことがあるため、
    /// UILabelが関知しない独自の名前で持つ。押されたリンクは`LinkLabel`がこの属性から読む。
    static let linkDestination = NSAttributedString.Key("net.mizle.scia.linkDestination")
}
