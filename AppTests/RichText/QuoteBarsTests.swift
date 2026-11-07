import Foundation
import SciaCore
import Testing
import SciaTesting
import TextKit2Label
import UIKit
@testable import Scia

/// 本文の引用の段落の頭に引く縦線の位置。
@Suite(.scratch)
@MainActor
struct QuoteBarsTests {
    private let width: CGFloat = 300
    private let indent: CGFloat = 16
    private let barWidth: CGFloat = 3

    private func label(
        _ blocks: [RichText.Block], barWidth: CGFloat? = nil, numberOfLines: Int = 0, drawsWithTextKit: Bool,
        direction: UISemanticContentAttribute = .unspecified
    ) -> LinkLabel {
        let text = RichTextRenderer(
            font: .preferredFont(forTextStyle: .body), textColor: .label, indentPerLevel: indent, quoteBarWidth: barWidth ?? self.barWidth,
            emojiImages: .offline, language: "ja"
        ).render(RichText(blocks: blocks))
        let label = LinkLabel()
        label.semanticContentAttribute = direction
        label.drawsWithTextKit = drawsWithTextKit
        label.numberOfLines = numberOfLines
        label.attributedText = text
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = CGRect(x: 0, y: 0, width: width, height: height)
        label.layoutIfNeeded()
        return label
    }

    private func block(_ text: String, quoteLevel: Int = 0) -> RichText.Block {
        .init(inlines: [.text(text, [])], quoteLevel: quoteLevel)
    }

    /// 各段落の行の枠。段落ごとに1行の文字列で使う。
    private func lines(of label: LinkLabel) -> [CGRect] {
        label.previewLines().map(\.frame)
    }

    /// 入れ子の引用では、深さの数だけ、各段の字下げの頭に線を引く。外側の線は、内側の引用をはさんだ前後の段落までつなげる。
    /// 引用の外の段落には伸ばさない。
    @Test(arguments: [false, true]) func nestedQuoteDrawsOneBarPerLevel(drawsWithTextKit: Bool) {
        let label = label([
            block("前"), block("外側", quoteLevel: 1), block("内側", quoteLevel: 2), block("外側に戻る", quoteLevel: 1), block("後"),
        ], drawsWithTextKit: drawsWithTextKit)
        let lines = lines(of: label)
        let bars = label.quoteBarFrames().sorted { $0.minX < $1.minX }

        #expect(lines.count == 5)
        #expect(bars.count == 2)
        #expect(bars.map(\.minX) == [0, indent])
        #expect(bars.map(\.width) == [barWidth, barWidth])
        #expect(bars[0].minY == lines[1].minY)
        #expect(bars[0].maxY > lines[3].minY && bars[0].maxY <= lines[3].maxY)
        #expect(bars[1].minY == lines[2].minY)
        #expect(bars[1].maxY > lines[2].minY && bars[1].maxY <= lines[2].maxY)
    }

    /// 同じ引用の段落が続くときは、段落のあいだも切らずに1本にする。
    @Test func consecutiveQuoteParagraphsShareOneBar() {
        let label = label([block("1つめ", quoteLevel: 1), block("2つめ", quoteLevel: 1)], drawsWithTextKit: true)
        let lines = lines(of: label)
        let bars = label.quoteBarFrames()

        #expect(bars.count == 1)
        #expect(bars.first?.minY == lines[0].minY)
        #expect((bars.first?.maxY ?? 0) > lines[1].minY)
    }

    /// 太さが0なら引かない。
    @Test func zeroWidthDrawsNoBar() {
        let label = label([block("引用", quoteLevel: 1)], barWidth: 0, drawsWithTextKit: true)

        #expect(label.quoteBarFrames().isEmpty)
    }

    /// 行数で切った本文では、見えている最後の行で止める。
    @Test func truncatedQuoteStopsAtLastVisibleLine() {
        let long = String(repeating: "長い引用の本文です。", count: 20)
        let label = label([block(long, quoteLevel: 1)], numberOfLines: 2, drawsWithTextKit: true)
        let bars = label.quoteBarFrames()

        #expect(bars.count == 1)
        #expect((bars.first?.maxY ?? .infinity) <= label.bounds.maxY + 0.5)
    }

    /// 字下げは段落の書き始めの側に空くので、線もその側に引き、本文に重ねない。画面の向きでは決めない。
    /// 左から右の画面の右から左に書く段落は右に、右から左の画面の左から右に書く段落は左に、字下げが空く。
    @Test(arguments: [
        (text: "اقتباس طويل بعض الشيء للتحقق من موضع الخط", direction: UISemanticContentAttribute.unspecified, isRightToLeft: true),
        (text: "A quoted English paragraph to check where the bar goes", direction: .forceRightToLeft, isRightToLeft: false),
    ])
    func barFollowsParagraphDirection(text: String, direction: UISemanticContentAttribute, isRightToLeft: Bool) throws {
        for drawsWithTextKit in [false, true] {
            let label = label([block(text, quoteLevel: 1)], drawsWithTextKit: drawsWithTextKit, direction: direction)
            let bar = try #require(label.quoteBarFrames().first)
            let layout = label.textLayout(of: try #require(label.attributedText))
            let glyphs = try (0..<text.utf16.count).compactMap {
                label.characterFrame(at: $0, in: try #require(label.attributedText), contentStorage: layout.contentStorage, layoutManager: layout.layoutManager)
            }.filter { $0.width > 0 }.reduce(CGRect.null) { $0.union($1) }

            #expect(bar.minX == (isRightToLeft ? width - barWidth : 0))
            #expect(isRightToLeft ? glyphs.maxX <= bar.minX : bar.maxX <= glyphs.minX, "線が本文に重なっています")
        }
    }

    /// 字下げは、本文の文字の大きさに合わせて伸び縮みする。文字を大きくしても、線とすき間が文字に比べて詰まらない。
    @Test func indentScalesWithFontSize() throws {
        func indent(fontSize: CGFloat) throws -> CGFloat {
            let text = RichTextRenderer(font: .systemFont(ofSize: fontSize), textColor: .label, emojiImages: .offline, language: "ja")
                .render(RichText(blocks: [block("引用", quoteLevel: 1)]))
            return try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle).headIndent
        }

        #expect(try indent(fontSize: 30) == 2 * indent(fontSize: 15))
    }
}
