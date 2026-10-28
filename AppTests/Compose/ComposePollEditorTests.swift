import SciaCore
import Testing
import UIKit
@testable import Scia

/// 投稿欄の投票の欄。選択肢の欄の増減を、投稿欄の高さを変える動きの中で見せる。
@MainActor
struct ComposePollEditorTests {
    private func content(_ options: [String]) -> ComposePollEditor.Content {
        ComposePollEditor.Content(poll: PollDraft(options: options), expiryChoices: PollDraft.expiryChoices)
    }

    private func laidOutEditor(_ options: [String]) -> ComposePollEditor {
        let editor = ComposePollEditor(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        editor.apply(content(options))
        editor.layoutIfNeeded()
        return editor
    }

    /// 増えた欄は、動き始めに透明で、並ぶ場所（前の欄のすぐ下）に置かれている。大きさ0から広がったり、1コマで出たりしない。
    @Test func addedRowStartsTransparentAtItsPlace() throws {
        let editor = laidOutEditor(["a", ""])
        let previous = try #require(editor.fields.last?.superview?.superview)

        #expect(editor.apply(content(["a", "b", ""]), animatesRows: true))

        let added = try #require(editor.fields.last?.superview?.superview)
        #expect(added.alpha == 0)
        #expect(added.frame.minY > previous.frame.maxY)
        #expect(added.frame.width == previous.frame.width)
        #expect(added.frame.height == previous.frame.height)
        let leaving = editor.revealRowChanges()
        #expect(leaving.isEmpty)
        #expect(added.alpha == 1)
    }

    /// 減った欄は、動き終えるまで元の場所に残して薄くし、終えてから外す。
    @Test func removedRowStaysInPlaceUntilFinished() throws {
        let editor = laidOutEditor(["a", "b", ""])
        let removed = try #require(editor.fields.last?.superview?.superview)
        let frame = removed.frame

        #expect(editor.apply(content(["a", ""]), animatesRows: true))
        editor.layoutIfNeeded()

        #expect(editor.fields.count == 2)
        #expect(removed.superview != nil)
        #expect(removed.frame == frame)
        let leaving = editor.revealRowChanges()
        #expect(leaving == [removed])
        #expect(removed.alpha == 0)
        editor.finishRowChanges(leaving)
        #expect(removed.superview == nil)
    }

    /// 折りたたんでいても、開いたときの高さを測れる。隠した欄の高さを0と測ると、置く側が収まると取り違えて、すぐ開き直してしまう。
    @Test func unfoldedHeightIsSameWhileFolded() {
        let editor = laidOutEditor(["a", "b", "c", ""])
        let unfolded = editor.unfoldedHeight(width: 320)
        #expect(abs(unfolded - editor.systemLayoutSizeFitting(CGSize(width: 320, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height) < 0.5)

        editor.setFolded(true)
        editor.layoutIfNeeded()

        #expect(editor.unfoldedHeight(width: 320) == unfolded)
        #expect(editor.systemLayoutSizeFitting(CGSize(width: 320, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height < unfolded / 2)
    }

    /// 設定の行の幅が足りなくなるにつれ、結果のボタンを先に「見せる」に縮め、それでも足りなければ選び方のボタンも「1つ」に縮める。
    /// 読み上げる値は、縮めても元の文言のまま。
    @Test func settingsLabelsShortenAsWidthNarrows() throws {
        let editor = laidOutEditor(["a", "b", ""])
        var seen: [SettingsLabelLength] = []
        for width in stride(from: 600, through: 150, by: -5) {
            editor.frame.size.width = CGFloat(width)
            editor.layoutIfNeeded()
            if seen.last != editor.labelLength {
                seen.append(editor.labelLength)
            }
        }
        #expect(seen == [.full, .shortResults, .shortBoth])

        let hidesTotals = try #require(buttons(in: editor).first { $0.accessibilityLabel == "結果" })
        let multiple = try #require(buttons(in: editor).first { $0.accessibilityLabel == "選び方" })
        #expect(hidesTotals.configuration?.title == "見せる")
        #expect(multiple.configuration?.title == "1つ")
        #expect(hidesTotals.accessibilityValue == "結果を見せる")
        #expect(multiple.accessibilityValue == "1つ選ぶ")
    }

    private func buttons(in view: UIView) -> [UIButton] {
        (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
    }

    /// 動かさないときは、これまでどおり、すぐ足して外す。
    @Test func rowsChangeAtOnceWithoutAnimation() throws {
        let editor = laidOutEditor(["a", "b", ""])
        let removed = try #require(editor.fields.last?.superview?.superview)

        editor.apply(content(["a", ""]))

        #expect(removed.superview == nil)
        #expect(editor.revealRowChanges().isEmpty)
    }
}
