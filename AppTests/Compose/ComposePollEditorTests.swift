import SciaCore
import Testing
import UIKit
@testable import Scia

/// 投稿欄の投票の欄。選択肢の欄の増減を、投稿欄の高さを変える動きの中で見せる。
@MainActor
@Suite(.failureState)
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

    /// 設定の行の幅が足りなくなるにつれ、結果のボタンを先に「表示」に縮め、それでも足りなければ選び方のボタンも「1つ」に縮める。
    @Test func settingsLabelsShortenAsWidthNarrows() {
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
    }

    /// 締め切りの文字が長くなって行に収まらなくなったら、幅が変わらなくても、値を替えるのと同時に文言を縮める。
    @Test func settingsLabelsShortenWhenExpiryGrows() throws {
        let editor = laidOutEditor(["a", "b", ""])
        let width = try #require(stride(from: 600, through: 150, by: -1).first { width in
            editor.frame.size.width = CGFloat(width)
            editor.layoutIfNeeded()
            return editor.labelLength != .full
        })
        editor.frame.size.width = CGFloat(width + 1)
        editor.layoutIfNeeded()
        #expect(editor.labelLength == .full)

        var poll = PollDraft(options: ["a", "b", ""])
        poll.expiresIn = 43_200
        editor.apply(ComposePollEditor.Content(poll: poll, expiryChoices: PollDraft.expiryChoices))

        #expect(editor.labelLength == .shortResults)
    }

    /// 増えた欄のマークは、浮かび上がらせる前に、今の選び方の形で置かれている。あとから置くと、マークが大きさ0から広がるところが動きに乗る。
    @Test func addedRowHasIndicatorBeforeReveal() throws {
        var poll = PollDraft(options: ["a", ""], multiple: true)
        let editor = ComposePollEditor(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        editor.apply(ComposePollEditor.Content(poll: poll, expiryChoices: PollDraft.expiryChoices))
        editor.layoutIfNeeded()

        poll.options = ["a", "b", ""]
        editor.apply(ComposePollEditor.Content(poll: poll, expiryChoices: PollDraft.expiryChoices), animatesRows: true)

        let added = try #require(editor.fields.last?.superview?.superview)
        let mark = try #require(marks(in: added).first)
        #expect(mark.multiple)
        #expect(mark.frame.width > 0)
        #expect(mark.frame.height > 0)
    }

    /// 選び方を変えると、どの欄のマークも、丸と四角の間で形を変える。
    @Test func marksFollowMultiple() {
        var poll = PollDraft(options: ["a", "b", ""])
        let editor = ComposePollEditor(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        editor.apply(ComposePollEditor.Content(poll: poll, expiryChoices: PollDraft.expiryChoices))
        editor.layoutIfNeeded()
        #expect(marks(in: editor).map(\.multiple) == [false, false, false])

        poll.multiple = true
        editor.apply(ComposePollEditor.Content(poll: poll, expiryChoices: PollDraft.expiryChoices))

        #expect(marks(in: editor).map(\.multiple) == [true, true, true])
    }

    /// 開いている間は、設定の行を切り抜かない。締め切りのメニューが閉じて戻ってくるボタンは、行の外から入るため、切り抜くと欠けて見える。
    @Test func settingsRowIsNotClippedWhileUnfolded() throws {
        let editor = laidOutEditor(["a", "b", ""])
        let row = try #require(settingsRow(in: editor))
        var view: UIView? = row
        while let current = view, current !== editor {
            #expect(!current.clipsToBounds)
            view = current.superview
        }
    }

    private func marks(in view: UIView) -> [ComposePollOptionMark] {
        (view as? ComposePollOptionMark).map { [$0] } ?? view.subviews.flatMap(marks(in:))
    }

    private func settingsRow(in view: UIView) -> ComposePollSettingsRow? {
        (view as? ComposePollSettingsRow) ?? view.subviews.lazy.compactMap(settingsRow(in:)).first
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
