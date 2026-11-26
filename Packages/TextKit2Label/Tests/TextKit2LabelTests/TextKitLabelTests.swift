import Testing
import UIKit
@testable import TextKit2Label

/// 絵文字やリンクを持たない`TextKitLabel`だけで、TextKit 2で測って文字の位置を求められる。Sciaの型なしで、この形で使えることを確かめる。
@MainActor
struct TextKitLabelTests {
    private let width: CGFloat = 300

    private func label(_ string: String) -> TextKitLabel {
        let label = TextKitLabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.drawsWithTextKit = true
        label.attributedText = NSAttributedString(string: string)
        return label
    }

    /// 大きさは、TextKit 2で並べた結果と同じにする。フォントのない文字列も、ラベルのフォントで並べる。
    @Test func sizeMatchesTextKitLayout() throws {
        let label = label(String(repeating: "長い本文です。", count: 20))
        let filled = TextKitLabelLayout.filled(try #require(label.assignedText), style: label.textKitStyle)
        let layout = TextKitLabelLayout.layout(of: filled, width: width, maximumLines: 0, style: label.textKitStyle)
        let metrics = try #require(TextKitLabelLayout.metrics(of: layout, displayScale: label.textKitStyle.displayScale))

        #expect(metrics.lineCount > 1)
        #expect(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height == metrics.size.height)
        #expect(label.textKitLineCount(width: width) == metrics.lineCount)
    }

    /// 押下した点の文字は、その文字を描いた枠から求める。描いている文字列は`attributedText`で読め、UILabelに渡した空白1文字は出さない。
    @Test func characterAtPointIsTheDrawnCharacter() throws {
        let label = label("あいうえお")
        label.frame = CGRect(origin: .zero, size: label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)))
        let text = try #require(label.attributedText)
        let layout = label.textLayout(of: text)
        let frame = try #require(label.characterFrame(at: 2, in: text, contentStorage: layout.contentStorage, layoutManager: layout.layoutManager))

        #expect(text.string == "あいうえお")
        #expect(label.accessibilityLabel == "あいうえお")
        #expect(label.characterIndex(at: CGPoint(x: frame.midX, y: frame.midY)) == 2)
    }

    /// TextKit 2で描くラベルに`text`で入れた文字も、TextKit 2で描いて測る。前の`attributedText`の文字を描き続けない。
    @Test func plainTextReplacesDrawnText() {
        let label = label(String(repeating: "長い本文です。", count: 20))
        label.text = "短い"

        #expect(label.text == "短い")
        #expect(label.attributedText?.string == "短い")
        #expect(label.textKitLineCount(width: width) == 1)
        label.text = nil
        #expect(label.text == nil)
        #expect(label.textKitLineCount(width: width) == 0)
    }

    /// 重ねて描く字形の場所取りは、2文字以上の絵文字（サロゲートペア、結合子でつないだ絵文字）でも、行の高さに入る。
    /// iOS 26のTextKit 2は、場所取りの後ろの幅のない文字によって、場所取りの枠を行の高さに入れない。
    @Test(arguments: ["⌚", "😁", "👨‍👩‍👧"]) func overlaidGlyphPlaceholderSetsLineHeight(emoji: String) throws {
        let font = UIFont.systemFont(ofSize: 17)
        let text = NSAttributedString(string: emoji, attributes: [.font: font.withSize(50), .overlaidGlyphs: font])
        let style = TextKitLabelLayout.Style(font: font, textColor: .label, lineBreakMode: .byWordWrapping, direction: .leftToRight, displayScale: 2, overlaysGlyphs: true)
        let layout = TextKitLabelLayout.layout(of: text, width: width, maximumLines: 0, style: style)
        let placed = try #require(layout.overlaidText)
        let placeholder = try #require(placed.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let metrics = try #require(TextKitLabelLayout.metrics(of: layout, displayScale: 2))

        #expect(placeholder.bounds.height > font.lineHeight * 2)
        #expect(metrics.firstBaseline >= placeholder.bounds.maxY - 0.5)
        #expect(metrics.size.height >= placeholder.bounds.height - 0.5)
    }
}
