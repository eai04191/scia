import Foundation
import SciaCore
import Testing
@testable import Scia

@MainActor
struct ComposeModelTests {
    private struct Failure: Error, LocalizedError {
        var errorDescription: String? { "失敗しました" }
    }

    private func status(visibility: Status.Visibility) throws -> Status {
        Status(
            id: "10",
            createdAt: .now,
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: try #require(URL(string: "https://example.social/a.png"))),
            content: "",
            spoilerText: "",
            url: nil,
            visibility: visibility
        )
    }

    @Test func defaultVisibilityAppliesUntilUserChooses() {
        let model = ComposeModel(replyTo: nil, myAccountID: "1") { _ in }

        model.apply(configuration: nil, defaultVisibility: .unlisted)
        #expect(model.visibility == .unlisted)

        model.choose(.private)
        model.apply(configuration: nil, defaultVisibility: .public)
        #expect(model.visibility == .private)
    }

    /// 既定の公開範囲が分かるまでは、公開範囲を選んでいなければ投稿できない。既定より広い範囲で投稿してしまわないため。
    @Test func cannotPostUntilDefaultVisibilityIsKnownOrChosen() {
        let model = ComposeModel(replyTo: nil, myAccountID: "1") { _ in }
        model.text = "こんにちは"
        #expect(!model.canPost)

        model.apply(configuration: nil, defaultVisibility: .private)
        #expect(model.canPost)

        let chosen = ComposeModel(replyTo: nil, myAccountID: "1") { _ in }
        chosen.text = "こんにちは"
        chosen.choose(.unlisted)
        #expect(chosen.canPost)
    }

    /// 既定の公開範囲を読めなかったときも、投稿できないままにはしない。
    @Test func canPostAfterDefaultsFailedToLoad() {
        let model = ComposeModel(replyTo: nil, myAccountID: "1") { _ in }
        model.text = "こんにちは"

        model.apply(configuration: nil, defaultVisibility: nil)

        #expect(model.canPost)
    }

    @Test func changedContentIsSentWithNewIdempotencyKey() async {
        var sent: [StatusDraft] = []
        let model = ComposeModel(replyTo: nil, myAccountID: "1") { draft in
            sent.append(draft)
            throw Failure()
        }
        model.apply(configuration: nil, defaultVisibility: .public)
        model.text = "一回目"

        await model.submit()
        await model.submit()
        model.text = "二回目"
        await model.submit()
        model.choose(.private)
        await model.submit()

        #expect(sent.count == 4)
        #expect(sent[0].idempotencyKey == sent[1].idempotencyKey)
        #expect(sent[1].idempotencyKey != sent[2].idempotencyKey)
        #expect(sent[2].idempotencyKey != sent[3].idempotencyKey)
    }

    @Test func replyVisibilityIsNarrowedByDefault() throws {
        let model = ComposeModel(replyTo: try status(visibility: .public), myAccountID: "1") { _ in }

        model.apply(configuration: nil, defaultVisibility: .unlisted)

        #expect(model.visibility == .unlisted)
        #expect(model.text == "@bob ")
        // 宛先を入れただけでは書きかけにしない。
        #expect(!model.isDirty)
    }

    @Test func appliesInstanceCharacterLimit() throws {
        let model = ComposeModel(replyTo: nil, myAccountID: "1") { _ in }
        model.choose(.public)
        model.text = String(repeating: "あ", count: 600)
        #expect(!model.canPost)

        model.apply(configuration: InstanceConfiguration(streamingURL: try #require(URL(string: "wss://example.social")), maxCharacters: 1000, charactersReservedPerURL: 23), defaultVisibility: nil)

        #expect(model.remainingCharacters == 400)
        #expect(model.canPost)
    }

    @Test func keepsDraftAndKeyWhenPostingFails() async {
        var sent: [StatusDraft] = []
        var finished = false
        var fails = true
        let model = ComposeModel(replyTo: nil, myAccountID: "1") { draft in
            sent.append(draft)
            if fails { throw Failure() }
        }
        model.onFinish = { finished = true }
        model.apply(configuration: nil, defaultVisibility: .public)
        model.text = "こんにちは"
        model.spoilerText = "隠した注意書き"

        await model.submit()
        #expect(model.errorMessage == "失敗しました")
        #expect(!finished)
        #expect(model.text == "こんにちは")

        fails = false
        await model.submit()
        #expect(finished)
        #expect(sent.count == 2)
        #expect(sent[0].idempotencyKey == sent[1].idempotencyKey)
        // 注意書きの欄を隠していれば、注意書きは送らない。
        #expect(sent.allSatisfy { $0.spoilerText.isEmpty })
    }

    @Test func cancelAsksBeforeDiscardingText() {
        var finished = false
        let model = ComposeModel(replyTo: nil, myAccountID: "1") { _ in }
        model.onFinish = { finished = true }

        model.text = "書きかけ"
        model.cancel()

        #expect(model.isDiscardConfirmationPresented)
        #expect(!finished)
    }
}
