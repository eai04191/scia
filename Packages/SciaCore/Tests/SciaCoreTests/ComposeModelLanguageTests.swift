import Foundation
@testable import SciaCore
import SciaTesting
import Testing

/// 投稿欄の言語。決まりはdocs/compose.mdの「投稿の言語」にある。
@MainActor
struct ComposeModelLanguageTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeModel(defaultLanguage: String?? = .some("ja"), post: @escaping (StatusDraft) async throws -> Void = { _ in }) -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", post: post)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, defaultLanguage: defaultLanguage)
        return model
    }

    private func status(language: String?) -> Status {
        Status(
            id: "10",
            createdAt: Self.now,
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: URL(string: "https://example.social/a.png")),
            content: "<p>hello</p>",
            spoilerText: "",
            language: language,
            url: nil,
            mediaAttachments: [],
            sensitive: false,
            visibility: .public
        )
    }

    /// 書き始めたときの言語はアカウントの既定にし、既定のままならコードを見せない。
    @Test func startsWithDefaultLanguage() async {
        var sent: [StatusDraft] = []
        let model = makeModel { sent.append($0) }
        model.text = "おはよう"

        #expect(model.language == "ja")
        #expect(!model.choosesNonDefaultLanguage)
        await model.submit()
        #expect(sent.map(\.language) == ["ja"])
    }

    /// 既定の言語を決めていなければ、送らずにサーバーに任せる。
    @Test func leavesLanguageToServerWithoutDefault() async {
        var sent: [StatusDraft] = []
        let model = makeModel(defaultLanguage: .some(nil)) { sent.append($0) }
        model.text = "おはよう"

        await model.submit()

        #expect(sent.map(\.language) == [nil])
        #expect(!model.choosesNonDefaultLanguage)
    }

    /// 選んだ言語で送り、送れたら次の投稿は既定の言語に戻す。
    @Test func chosenLanguageIsResetAfterPosting() async {
        var sent: [StatusDraft] = []
        let model = makeModel { sent.append($0) }
        model.text = "hello"

        model.choose(language: "en")
        #expect(model.choosesNonDefaultLanguage)
        await model.submit()

        #expect(sent.map(\.language) == ["en"])
        #expect(model.language == "ja")
        #expect(!model.choosesNonDefaultLanguage)
    }

    /// 選んだあとに既定の言語が届いても、選んだ言語を上書きしない。
    @Test func defaultArrivingLaterKeepsChosenLanguage() {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }

        model.choose(language: "en")
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, defaultLanguage: .some("ja"))

        #expect(model.language == "en")
        #expect(model.defaultLanguage == "ja")
    }

    /// 返信先を付けても、相手の投稿の言語を引き継がない。
    @Test func replyDoesNotInheritLanguage() {
        let model = makeModel()

        model.setReplyTarget(status(language: "en"))

        #expect(model.language == "ja")
    }

    /// 自分の投稿の編集では、その投稿の言語で始める。既定と違えばコードを見せる。
    @Test func editingStartsWithStatusLanguage() throws {
        let model = makeModel()

        #expect(model.beginEditing(status(language: "en"), source: StatusSource(id: "10", text: "hello", spoilerText: ""), now: Self.now))

        #expect(model.language == "en")
        #expect(model.choosesNonDefaultLanguage)
        model.reset()
        #expect(model.language == "ja")
    }

    /// 予約を書き直すときは、予約したときの言語を戻し、あとから届く既定で上書きしない。
    @Test func rewritingRestoresScheduledLanguage() {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        let scheduled = ScheduledStatus(id: "70", scheduledAt: Self.now.addingTimeInterval(3 * 60 * 60), params: ScheduledStatus.Params(text: "hello", language: "en"))

        model.beginRewriting(scheduled)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, defaultLanguage: .some("ja"))

        #expect(model.language == "en")
    }
}
