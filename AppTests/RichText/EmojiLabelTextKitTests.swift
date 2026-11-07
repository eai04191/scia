import Foundation
import SciaCore
import Testing
import SciaTesting
import TextKit2Label
import UIKit
@testable import Scia

/// TextKit 2で描くときの、本文のラベルの大きさ。
@Suite(.scratch)
@MainActor
struct EmojiLabelTextKitTests {
    private let width: CGFloat = 300

    private func label() -> LinkLabel {
        let label = LinkLabel()
        label.numberOfLines = 0
        label.drawsWithTextKit = true
        return label
    }

    private func height(of label: LinkLabel) -> CGFloat {
        label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private func text(_ string: String) -> NSAttributedString {
        RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: .offline, language: "ja")
            .render(RichText(blocks: [.init(inlines: [.text(string, [])])]))
    }

    /// 空の本文は高さを取らない。UILabelに渡している空白1文字の高さを返さない。
    @Test func emptyTextHasNoHeight() {
        let label = label()
        label.attributedText = NSAttributedString()

        #expect(height(of: label) == 0)
        #expect(label.textKitBaselines(width: width) == (0, 0))
    }

    /// 使い回したラベルに短い本文を入れたら、前の長い本文で測った高さを返さない。
    /// UILabelは文字列を入れる中で大きさを測り直して覚えるため、測った結果を入れたあとに捨てると、前の本文の高さのままになった。
    @Test func reusedLabelMeasuresNewText() {
        let label = label()
        label.attributedText = text(String(repeating: "長い本文です。", count: 30))
        let long = height(of: label)
        label.attributedText = text("短い")
        let short = height(of: label)

        #expect(short < long / 5)
        #expect(label.intrinsicContentSize.height == short)
    }

    /// 最後の行のカスタム絵文字がベースラインより下へ伸びるときは、その下端まで高さに含める。
    /// 含めないと、下に部品のない本文で、絵文字が次の投稿に重なる。
    @Test func lastLineAttachmentBelowBaselineIsIncluded() {
        let attachment = NSTextAttachment()
        attachment.image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 60)).image { _ in }
        attachment.bounds = CGRect(x: 0, y: -40, width: 20, height: 60)
        let string = NSMutableAttributedString(attributedString: text("絵文字"))
        string.append(NSAttributedString(attachment: attachment))
        let label = label()
        label.attributedText = string

        let baselines = label.textKitBaselines(width: width)
        #expect(baselines.lastFromBottom >= 40)
        #expect(height(of: label) >= baselines.first + 40)
    }
}
