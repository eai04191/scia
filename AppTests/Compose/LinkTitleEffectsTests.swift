import SciaCore
import Testing
import UIKit
@testable import Scia

/// 投稿欄でリンクにタイトルを付けるときに、本文の上に重ねる見た目。
@MainActor
struct LinkTitleEffectsTests {
    private func shimmers(in textView: UITextView) -> [UIView] {
        textView.subviews.filter { String(describing: type(of: $0)) == "ShimmerView" }
    }

    /// 読んでいる間にURLの後ろへ打っても、流れているきらめきを作り直さず、同じものが流れ続ける。
    /// 作り直すと、流れている途中の光が1コマで消え、左端から流れ直す。
    @Test func typingKeepsShimmer() throws {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        textView.font = .preferredFont(forTextStyle: .body)
        textView.text = "https://example.com/a "
        textView.layoutIfNeeded()
        let effects = LinkTitleEffects(textView: textView, tuning: TuningStore(defaults: nil))
        let occurrence = try #require(LinkTitling.occurrences(in: textView.text).first)
        _ = effects.beginLoading(occurrence)
        let before = shimmers(in: textView)
        #expect(!before.isEmpty)

        textView.text += "abc"
        textView.layoutIfNeeded()
        effects.textDidChange(textView.text)

        let after = shimmers(in: textView)
        #expect(after.count == before.count)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
        #expect(after.allSatisfy { $0.alpha == 1 })
    }

    /// URLの前に打ってURLが動いたら、同じきらめきを新しい場所へ置き直す。
    @Test func typingBeforeLinkMovesShimmer() throws {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        textView.font = .preferredFont(forTextStyle: .body)
        textView.text = "https://example.com/a"
        textView.layoutIfNeeded()
        let effects = LinkTitleEffects(textView: textView, tuning: TuningStore(defaults: nil))
        let occurrence = try #require(LinkTitling.occurrences(in: textView.text).first)
        _ = effects.beginLoading(occurrence)
        let before = try #require(shimmers(in: textView).first)
        let frame = before.frame

        textView.text = "xx " + textView.text
        textView.layoutIfNeeded()
        effects.textDidChange(textView.text)

        let after = try #require(shimmers(in: textView).first)
        #expect(after === before)
        #expect(after.frame.minX > frame.minX)
    }
}
