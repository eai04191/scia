import Foundation
@testable import SciaCore
import SciaTesting
import Testing

/// 投稿の削除と、削除した投稿をセッションの一覧から除くこと。
@MainActor
struct StatusDeletionTests {
    /// 渡された変化を記録する一覧。
    private final class RecordingList: SessionStatusList {
        var removed: [Status.ID] = []
        var updated: [Status.ID] = []

        func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
            updated.append(id)
        }

        func removeStatus(_ id: Status.ID) {
            removed.append(id)
        }
    }

    private func status(id: String, reblogging reblogged: Status? = nil) -> Status {
        Status(
            id: id,
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "1", username: "me", acct: "me", displayName: "Me", avatar: nil),
            content: "",
            spoilerText: "",
            url: nil,
            reblog: reblogged
        )
    }

    /// 消せたら、登録したどの一覧からも除き、引用元としても消えたことにする。ブーストを渡せば、ブーストされた投稿を消す。
    @Test func removesFromEveryListAndQuoteSources() async throws {
        let statuses = SessionStatuses()
        let lists = [RecordingList(), RecordingList()]
        lists.forEach(statuses.register)
        var quoteChanges: [QuoteSourceChange] = []
        statuses.onQuoteSourcesChange = { _, change in quoteChanges.append(change) }
        var sent: [Status.ID] = []
        var deleted: [Status.ID] = []
        let deletion = StatusDeletion(deleteStatus: { sent.append($0) }, statuses: statuses, tasks: TaskScope()) { deleted.append($0) }

        deletion.delete(status(id: "20", reblogging: status(id: "10"))) { _ in Issue.record("失敗しないはず") }
        try await waitUntil { deleted == ["10"] }

        #expect(sent == ["10"])
        #expect(lists.map(\.removed) == [["10"], ["10"]])
        #expect(quoteChanges == [.status("10")])
        #expect(statuses.quoteSources != QuoteSourceChanges())
    }

    /// 消せなかったら、一覧にも投稿欄にも触れずに失敗を渡す。
    @Test func failureLeavesListsUntouched() async throws {
        let statuses = SessionStatuses()
        let list = RecordingList()
        statuses.register(list)
        var failures = 0
        let deletion = StatusDeletion(deleteStatus: { _ in throw MastodonAPIError(statusCode: 500, message: "") }, statuses: statuses, tasks: TaskScope()) { _ in
            Issue.record("消せていない")
        }

        deletion.delete(status(id: "10")) { _ in failures += 1 }
        try await waitUntil { failures == 1 }

        #expect(list.removed.isEmpty)
        #expect(statuses.quoteSources == QuoteSourceChanges())
    }

    /// 送り終える前に押し直しても、同じ削除を重ねて送らない。
    @Test func skipsWhileDeletingSameStatus() async throws {
        let gate = Gate()
        var sent = 0
        var deleted = 0
        let deletion = StatusDeletion(deleteStatus: { _ in
            sent += 1
            try await gate.wait()
        }, statuses: SessionStatuses(), tasks: TaskScope()) { _ in deleted += 1 }

        deletion.delete(status(id: "10")) { _ in }
        try await waitUntil { sent == 1 }
        deletion.delete(status(id: "10")) { _ in }
        gate.open()
        try await waitUntil { deleted == 1 }

        #expect(sent == 1)
    }

    /// 消えた一覧は、外さなくても配り先から消える。
    @Test func releasedListIsNotKept() throws {
        let statuses = SessionStatuses()
        var list: RecordingList? = RecordingList()
        weak let released = list
        statuses.register(try #require(list))
        list = nil
        statuses.removeStatus("10")
        #expect(released == nil)
    }
}

/// 自分の投稿を消したときに、投稿欄で編集や書き直しをやめる。決まりはdocs/compose.mdにある。
@MainActor
struct ComposeModelStatusDeletionTests {
    private func status(id: String) -> Status {
        Status(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            account: Account(id: "1", username: "me", acct: "me", displayName: "Me", avatar: nil),
            content: "<p>元の本文</p>",
            spoilerText: "",
            url: nil
        )
    }

    private func makeModel(post: @escaping (StatusDraft) async throws -> Void = { _ in }) -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", post: post)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        return model
    }

    /// 編集している投稿を消したら、画面の片づけを呼んでから、編集をやめて空に戻す。ほかの投稿を消しても何もしない。
    @Test func deletingEditedStatusStopsEditing() {
        let model = makeModel()
        #expect(model.beginEditing(status(id: "10"), source: StatusSource(id: "10", text: "前の本文", spoilerText: ""), now: Date(timeIntervalSince1970: 1_800_000_000)))
        var cleanedUp = 0

        model.statusWasDeleted("99") { cleanedUp += 1 }
        #expect(model.editedStatus?.id == "10")

        model.statusWasDeleted("10") { cleanedUp += 1 }
        #expect(model.editedStatus == nil)
        #expect(model.text.isEmpty)
        #expect(cleanedUp == 1)
    }

    /// 削除して書き直している元の投稿を消したら、書き直しをやめる。
    @Test func deletingRedraftedStatusStopsRedrafting() {
        let model = makeModel()
        #expect(model.beginRedrafting(status(id: "10"), source: StatusSource(id: "10", text: "前の本文", spoilerText: "")))

        model.statusWasDeleted("10")
        #expect(model.redraft == nil)
        #expect(model.text.isEmpty)
    }

    /// ほかのアカウントで書いているときに今のアカウントの投稿が消えても、IDが同じでも別の投稿なのでやめない。
    @Test func deletionOfOtherAccountIsIgnored() {
        let model = makeModel()
        #expect(model.beginEditing(status(id: "10"), source: StatusSource(id: "10", text: "前の本文", spoilerText: ""), now: Date(timeIntervalSince1970: 1_800_000_000)))

        model.statusWasDeleted("10", accountID: "other")
        #expect(model.editedStatus?.id == "10")
    }

    /// 編集を送っている間に消したら、送り直せるよう下書きを残す。
    @Test func editBeingSentIsKept() async throws {
        let gate = Gate()
        let model = makeModel { _ in try await gate.wait() }
        #expect(model.beginEditing(status(id: "10"), source: StatusSource(id: "10", text: "前の本文", spoilerText: ""), now: Date(timeIntervalSince1970: 1_800_000_000)))
        model.text = "直した本文"
        let submitting = Task { await model.submit() }
        try await waitUntil { model.isPosting }

        model.statusWasDeleted("10")
        #expect(model.editedStatus?.id == "10")
        #expect(model.text == "直した本文")
        gate.open()
        await submitting.value
    }
}
