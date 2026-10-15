import Testing
import UIKit
@testable import Scia

@MainActor
struct FadingLabelTests {
    private func label(text: String, width: CGFloat) -> FadingLabel {
        let label = FadingLabel()
        label.attributedText = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 17)])
        label.frame = CGRect(x: 0, y: 0, width: width, height: 22)
        label.layoutIfNeeded()
        return label
    }

    @Test func fadesOnlyWhenTruncated() {
        #expect(label(text: "短い名前", width: 300).layer.mask == nil)
        #expect(label(text: String(repeating: "とても長い名前", count: 10), width: 100).layer.mask != nil)
    }

    /// 長い名前のセルを再利用して短い名前を出したら、ぼかしを外す。
    @Test func removesFadeWhenTextFitsAgain() {
        let reused = label(text: String(repeating: "とても長い名前", count: 10), width: 100)

        reused.attributedText = NSAttributedString(string: "短い", attributes: [.font: UIFont.systemFont(ofSize: 17)])
        reused.layoutIfNeeded()

        #expect(reused.layer.mask == nil)
    }

    /// 名前の文字列には段落スタイルが付いていて、ラベルのlineBreakModeより優先される。単語の切れ目で切らず、行末までぼかしにかかるようにする。
    @Test func clipsEvenWhenParagraphStyleWrapsWords() {
        let label = FadingLabel()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        label.attributedText = NSAttributedString(string: "Very Long Display Name", attributes: [.paragraphStyle: style])

        let applied = label.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(applied?.lineBreakMode == .byClipping)
    }

    /// ぼかすのは文字の行末。画面の向きではなく、文字列の書字方向で決める。
    @Test(arguments: [
        ("Alice", false),
        ("えあい", false),
        ("שלום עולם", true),
        ("مرحبا", true),
        // 最初に向きの決まる文字で決める。絵文字や記号は向きを決めない。
        ("🦐 مرحبا", true),
        ("@alice", false),
    ])
    func fadesAtEndOfWritingDirection(_ text: String, isRightToLeft: Bool) {
        #expect(FadingLabel.isRightToLeft(text) == isRightToLeft)
    }
}

