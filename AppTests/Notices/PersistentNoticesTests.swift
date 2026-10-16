import Testing
@testable import Scia

/// 出たままの知らせが重なったときに、チップに出す1件。決まりはdocs/notices.mdの「チップ」にある。
@MainActor
struct PersistentNoticesTests {
    private let download = Notice(id: "download", kind: .progress, title: "ダウンロード中", value: "42%", action: .disclosure(hint: "ダウンロードを止めるか選べます。") {})
    private let uploadFailure = Notice(id: "upload", kind: .failure, title: "アップロードできませんでした", action: .disclosure(hint: "理由と、再試行か削除を選べます。") {})

    @Test func singleNoticeKeepsItsOwnAction() throws {
        var notices = PersistentNotices()
        notices.set(download, in: .download)

        let chip = try #require(notices.chipNotice {})
        #expect(chip.id == "download")
        #expect(chip.additionalCount == 0)
        guard case .disclosure(let hint, _) = chip.action else {
            Issue.record("押すと続きが出るはず")
            return
        }
        #expect(hint == "ダウンロードを止めるか選べます。")
    }

    @Test func failureWinsAndTappingOpensTheList() throws {
        var notices = PersistentNotices()
        notices.set(uploadFailure, in: .draft)
        notices.set(download, in: .download)
        var opened = false

        let chip = try #require(notices.chipNotice { opened = true })
        #expect(chip.id == "upload")
        #expect(chip.additionalCount == 1)
        guard case .disclosure(_, let handler) = chip.action else {
            Issue.record("押すと一覧が開くはず")
            return
        }
        handler()
        #expect(opened)
    }

    @Test func withoutListTheChosenNoticeKeepsItsAction() throws {
        var notices = PersistentNotices()
        notices.set(uploadFailure, in: .draft)
        notices.set(download, in: .download)

        let chip = try #require(notices.chipNotice(showAll: nil))
        guard case .disclosure(let hint, _) = chip.action else {
            Issue.record("押すと続きが出るはず")
            return
        }
        #expect(hint == "理由と、再試行か削除を選べます。")
    }

    @Test func updatingTheSameNoticeKeepsItsOrder() throws {
        var notices = PersistentNotices()
        notices.set(download, in: .download)
        notices.set(Notice(id: "upload", kind: .progress, title: "アップロード中"), in: .draft)
        var progressed = download
        progressed.value = "80%"
        notices.set(progressed, in: .download)

        // 書き換えたダウンロードより、あとから出たアップロードの方が新しい。
        #expect(notices.chipNotice {}?.id == "upload")

        notices.set(nil, in: .draft)
        #expect(notices.chipNotice {}?.text == "ダウンロード中 80%")
        notices.set(nil, in: .download)
        #expect(notices.chipNotice {} == nil)
    }
}
