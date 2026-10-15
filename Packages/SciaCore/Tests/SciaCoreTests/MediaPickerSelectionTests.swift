import Testing
@testable import SciaCore

struct MediaPickerSelectionTests {
    @Test func addsNewSelectionsInPickerOrder() {
        var selection = MediaPickerSelection()

        let changes = selection.changes(current: [], selected: ["b", "a"])

        #expect(changes.removed.isEmpty)
        #expect(changes.added == ["b", "a"])
    }

    @Test func removesDeselectedAndKeepsDraftOrder() {
        var selection = MediaPickerSelection()

        // 下書きでは c, a, b の順に並べ替えてある。ピッカーは自分の順で送ってくる。
        let changes = selection.changes(current: ["c", "a", "b"], selected: ["a", "b", "d"])

        #expect(changes.removed == ["c"])
        #expect(changes.added == ["d"])
    }

    @Test func ignoresItemsRemovedInDraftWhilePickerIsOpen() {
        var selection = MediaPickerSelection()
        selection.didRemoveInDraft("a", pickerIsOpen: true)

        // ピッカーではまだ a が選ばれたまま、別の写真を足した。
        let changes = selection.changes(current: ["b"], selected: ["a", "b", "c"])

        #expect(changes.added == ["c"])
    }

    @Test func reselectingAfterPickerDeselectAddsAgain() {
        var selection = MediaPickerSelection()
        selection.didRemoveInDraft("a", pickerIsOpen: true)

        _ = selection.changes(current: ["b"], selected: ["b"])
        let changes = selection.changes(current: ["b"], selected: ["b", "a"])

        #expect(changes.added == ["a"])
    }

    @Test func removalWithoutOpenPickerIsNotRemembered() {
        var selection = MediaPickerSelection()
        selection.didRemoveInDraft("a", pickerIsOpen: false)

        #expect(selection.removedWhilePickerOpen.isEmpty)
    }

    @Test func closingPickerForgetsRemovals() {
        var selection = MediaPickerSelection()
        selection.didRemoveInDraft("a", pickerIsOpen: true)

        selection.pickerDidClose()

        #expect(selection.changes(current: [], selected: ["a"]).added == ["a"])
    }
}
