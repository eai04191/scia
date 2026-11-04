import Foundation
@testable import SciaCore
import SciaTesting
import Testing

/// 投稿欄の＋の「下書きを捨てる」を押せるか。決まりはdocs/compose.mdの「＋のメニューとツールバー」にある。
@MainActor
struct ComposeModelDiscardTests {
    private func makeModel(post: @escaping (StatusDraft) async throws -> Void = { _ in }) -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", post: post)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        return model
    }

    private func status() -> Status {
        Status(
            id: "10",
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
            content: "",
            spoilerText: "",
            url: nil,
            visibility: .public
        )
    }

    /// 空の投稿欄では押せない。
    @Test func emptyDraftCannotBeDiscarded() {
        #expect(!makeModel().canDiscardDraft)
    }

    /// 書いたものだけでなく、返信先、空の投票の欄、注意書きの欄、予約、選んだ公開範囲のように、空の状態と違うものが1つでもあれば押せ、捨てると空の状態に戻る。
    @Test(arguments: ["text", "reply", "poll", "spoiler", "schedule", "visibility"])
    func anyChangeCanBeDiscarded(change: String) {
        let model = makeModel()
        switch change {
        case "text": model.text = "こんにちは"
        case "reply": model.setReplyTarget(status())
        case "poll": model.addPoll()
        case "spoiler": model.showsSpoiler = true
        case "schedule": model.addSchedule()
        default: model.choose(.private)
        }
        #expect(model.canDiscardDraft)

        model.reset()
        #expect(!model.canDiscardDraft)
    }

    /// 既定の言語があるときに「サーバーに任せる」を選んだだけでも、既定と違うので押せ、捨てると既定の言語に戻る。
    @Test func leavingLanguageToServerCanBeDiscarded() {
        let model = makeModel()
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, defaultLanguage: "ja")
        #expect(!model.canDiscardDraft)

        model.choose(language: nil)
        #expect(model.canDiscardDraft)

        model.reset()
        #expect(model.language == "ja")
        #expect(!model.canDiscardDraft)
    }

    /// 送っている間は、送れなかったときに送り直せるよう、押せない。
    @Test func cannotDiscardWhilePosting() async throws {
        let gate = Gate()
        let model = makeModel { _ in try await gate.wait() }
        model.text = "こんにちは"

        let posting = Task { await model.submit() }
        try await waitUntil { gate.waiterCount == 1 }
        #expect(!model.canDiscardDraft)
        gate.open()
        await posting.value
    }
}
