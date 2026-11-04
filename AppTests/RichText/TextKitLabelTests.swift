import Testing
import UIKit
@testable import Scia

/// 絵文字やリンクを持たない`TextKitLabel`だけで、TextKit 2で測って文字の位置を求められる。ほかのアプリへコピーしても、この形で使えることを確かめる。
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

    /// 押した点の文字は、その文字を描いた枠から求める。描いている文字列は`attributedText`で読め、UILabelに渡した空白1文字は出さない。
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
}
