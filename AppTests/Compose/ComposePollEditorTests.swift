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

    /// 動かさないときは、これまでどおり、すぐ足して外す。
    @Test func rowsChangeAtOnceWithoutAnimation() throws {
        let editor = laidOutEditor(["a", "b", ""])
        let removed = try #require(editor.fields.last?.superview?.superview)

        editor.apply(content(["a", ""]))

        #expect(removed.superview == nil)
        #expect(editor.revealRowChanges().isEmpty)
    }
}
