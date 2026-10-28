import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct AccountNoteEditorTests {
    /// 文字数の上限は手元で決めず、Mastodonの既定の上限（2000文字）より長くても保存させる。上限はサーバーが決めて断る。
    @Test func longNoteCanBeSavedBecauseServerDecidesLimit() {
        let editor = AccountNoteEditor(accountID: "2", note: "") { _, _ in Relationship(id: "2") }
        editor.text = String(repeating: "a", count: 10_000)

        #expect(editor.canSave)
    }

    /// 文字数は、サーバーと同じくコードポイントで数える。肌の色を付けた絵文字は、見た目は1文字でも2と数える。
    @Test func lengthCountsCodePoints() {
        let editor = AccountNoteEditor(accountID: "2", note: "") { _, _ in Relationship(id: "2") }
        editor.text = "メモ👍🏽"

        #expect(editor.length == 4)
    }

    /// 開いたときのままなら保存させない。消して空にしたものは変更として保存させる。
    @Test func savesOnlyChanges() {
        let editor = AccountNoteEditor(accountID: "2", note: "前に会った") { _, _ in Relationship(id: "2") }
        #expect(!editor.canSave)

        editor.text = ""
        #expect(editor.hasChanges)
        #expect(editor.canSave)
    }

    /// 保存したメモを、次の変更の元にする。
    @Test func savedNoteBecomesOriginal() async throws {
        let editor = AccountNoteEditor(accountID: "2", note: "") { id, comment in Relationship(id: id, note: comment) }
        editor.text = "前に会った"

        let saved = try await editor.save()

        #expect(saved.note == "前に会った")
        #expect(editor.original == "前に会った")
        #expect(!editor.hasChanges)
    }

    @Test func failedSaveKeepsText() async {
        struct Failure: Error {}
        let editor = AccountNoteEditor(accountID: "2", note: "") { _, _ in throw Failure() }
        editor.text = "書きかけ"

        await #expect(throws: Failure.self) { try await editor.save() }

        #expect(editor.text == "書きかけ")
        #expect(editor.hasChanges)
        #expect(!editor.isSaving)
    }

    /// 保存している間は保存させず、重ねて押しても1回だけ送る。
    @Test func refusesSecondSaveWhileSaving() async throws {
        let gate = Gate()
        let editor = AccountNoteEditor(accountID: "2", note: "") { id, comment in
            try await gate.wait()
            return Relationship(id: id, note: comment)
        }
        editor.text = "前に会った"
        let first = Task { try await editor.save() }
        try await waitUntil { gate.waiterCount == 1 }
        #expect(editor.isSaving)
        #expect(!editor.canSave)

        await #expect(throws: CancellationError.self) { try await editor.save() }

        gate.open()
        _ = try await first.value
        #expect(gate.waiterCount == 0)
        #expect(!editor.isSaving)
    }
}
