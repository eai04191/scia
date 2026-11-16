import SciaCore
import SwiftUI
import UIKit

/// 並べたアイテム（`TextLists.ItemList`）の区切りに引く境界線。文字の中に画像として埋めるので、1行で末尾を切るラベルにもそのまま入る。
enum ListSeparator {
    static let color = UIColor.tertiaryLabel

    /// 境界線の画像と、文字の並びの中での枠。線の左右に、文字の大きさに合わせた空きを持つ。
    static func image(for font: UIFont) -> (image: UIImage, bounds: CGRect) {
        let padding = (font.pointSize * 0.47).rounded()
        let overshoot: CGFloat = 2
        let size = CGSize(width: padding * 2 + 1, height: font.capHeight + overshoot * 2)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: padding, y: 0, width: 1, height: size.height))
        }
        return (image.withRenderingMode(.alwaysTemplate), CGRect(x: 0, y: -overshoot, width: size.width, height: size.height))
    }

    /// `text`を`attributes`で組み、区切りの範囲を境界線に置き換える。置き換えても長さは変わらないので、`text`の範囲はそのまま使える。
    static func attributedString(_ text: String, separators: [Range<String.Index>], font: UIFont, attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        var attributes = attributes
        attributes[.font] = font
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        replaceSeparators(separators, of: text, in: result, font: font)
        return result
    }

    /// `text`から組んだ`attributed`の、区切りの範囲を境界線に置き換える。名前の強調のように範囲へ色を付けたあとに呼び、境界線の色を上書きさせない。
    static func replaceSeparators(_ separators: [Range<String.Index>], of text: String, in result: NSMutableAttributedString, font: UIFont) {
        let (image, bounds) = image(for: font)
        for range in separators.reversed() {
            let attachment = NSTextAttachment(image: image)
            attachment.bounds = bounds
            let separator = NSMutableAttributedString(attachment: attachment)
            separator.addAttributes([.font: font, .foregroundColor: color, .listSeparator: true], range: NSRange(location: 0, length: separator.length))
            result.replaceCharacters(in: NSRange(range, in: text), with: separator)
        }
    }

    static func attributedString(_ list: TextLists.ItemList, font: UIFont, attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        attributedString(list.text, separators: list.separators, font: font, attributes: attributes)
    }
}

extension NSAttributedString.Key {
    /// 境界線の添付に付ける目印。文字として読むときに、区切りと見分ける。
    static let listSeparator = NSAttributedString.Key("net.mizle.scia.listSeparator")
}

extension NSAttributedString {
    /// 境界線を読み上げの区切りに戻した文字列。
    var stringSpeakingListSeparators: String {
        let result = NSMutableAttributedString(attributedString: self)
        var ranges: [NSRange] = []
        enumerateAttribute(.listSeparator, in: NSRange(location: 0, length: length)) { value, range, _ in
            if value != nil {
                ranges.append(range)
            }
        }
        for range in ranges.reversed() {
            result.replaceCharacters(in: range, with: TextLists.joined(["", ""]))
        }
        return result.string
    }
}

/// 並べたアイテムを、境界線で区切って1つの`Text`で描く。
struct ItemListText: View {
    let list: TextLists.ItemList
    /// 文字の大きさ。境界線の高さと空きを合わせる。
    let textStyle: UIFont.TextStyle

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let font = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize)))
        let (image, bounds) = ListSeparator.image(for: font)
        let separator = Text(Image(uiImage: image).renderingMode(.template))
            .foregroundStyle(Color(ListSeparator.color))
            .baselineOffset(bounds.minY)
        pieces.enumerated().reduce(Text(verbatim: "")) { text, piece in
            piece.offset == 0 ? Text(verbatim: piece.element) : Text("\(text)\(separator)\(Text(verbatim: piece.element))")
        }
        .accessibilityLabel(list.spoken)
    }

    private var pieces: [String] {
        var pieces: [String] = []
        var start = list.text.startIndex
        for range in list.separators {
            pieces.append(String(list.text[start..<range.lowerBound]))
            start = range.upperBound
        }
        pieces.append(String(list.text[start...]))
        return pieces
    }
}
