import Foundation
import Testing
import UIKit
@testable import Scia

/// 絵文字のリアクションの列。投稿では「投稿の見た目」の値で並べる。
@MainActor
@Suite(.failureState)
struct ReactionChipsViewTests {
    private static func reaction(_ name: String) -> ReactionChipsView.Reaction {
        ReactionChipsView.Reaction(name: name, emoji: NSAttributedString(string: name), count: 1, isMine: false, spokenName: name)
    }

    private static func chips(style: ReactionChipsView.Style) -> [CGRect] {
        let view = ReactionChipsView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        view.apply([reaction("👍"), reaction("🎉")], style: style)
        view.layoutIfNeeded()
        return view.chipPreviewFrames(in: view)
    }

    /// ボタンのあいだと文字の余白を、渡した値で並べる。
    @Test func laysOutChipsWithStyle() {
        var style = ReactionChipsView.Style.standard
        style.spacing = 20
        style.padding = NSDirectionalEdgeInsets(top: 12, leading: 30, bottom: 12, trailing: 30)
        let standard = Self.chips(style: .standard)
        let wide = Self.chips(style: style)

        #expect(wide.count == 3)
        #expect(wide[1].minX - wide[0].maxX == 20)
        #expect(wide[0].height == standard[0].height + 14)
        #expect(wide[0].width == standard[0].width + 40)
    }

    /// 左右の余白を大きくしても、狭い列で文字の幅を負にしない。余白は幅の半分までに縮め、ボタンを列の幅に収めて、文字が入る幅を残す。
    @Test func keepsLabelWidthInNarrowColumn() throws {
        var style = ReactionChipsView.Style.standard
        style.padding = NSDirectionalEdgeInsets(top: 5, leading: 100, bottom: 5, trailing: 100)
        let view = ReactionChipsView(frame: CGRect(x: 0, y: 0, width: 120, height: 100))
        view.apply([Self.reaction("👍")], style: style)
        view.layoutIfNeeded()
        let chip = try #require(view.subviews.compactMap { $0 as? ReactionChipButton }.first { $0.accessibilityLabel == "👍 1件" })

        #expect(chip.frame.width <= 120)
        let content = chip.label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width
        #expect(chip.label.frame.width >= content - 0.5)
        #expect(chip.label.frame.minX >= 0)
    }
}
