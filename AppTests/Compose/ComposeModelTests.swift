import Foundation
import SciaCore
import Testing
@testable import Scia

@MainActor
struct ComposeModelTests {
    private struct Failure: Error, LocalizedError {
        var errorDescription: String? { "失敗しました" }
    }

    private func status(visibility: Status.Visibility, spoilerText: String = "") throws -> Status {
        Status(
            id: "10",
            createdAt: .now,
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: try #require(URL(string: "https://example.social/a.png"))),
            content: "",
            spoilerText: spoilerText,
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
    }

    @Test func appliesInstanceCharacterLimit() throws {
        let model = ComposeModel(replyTo: nil, myAccountID: "1") { _ in }
        model.choose(.public)
        model.text = String(repeating: "あ", count: 600)
        #expect(!model.canPost)

        model.apply(configuration: InstanceConfiguration(streamingURL: try #require(URL(string: "wss://example.social")), maxCharacters: 1000, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil), defaultVisibility: nil)

        #expect(model.remainingCharacters == 400)
        #expect(model.canPost)
    }

    @Test func keepsDraftAndKeyWhenPostingFails() async {
        var sent: [StatusDraft] = []
        var posted = false
        var fails = true
        let model = ComposeModel(replyTo: nil, myAccountID: "1") { draft in
            sent.append(draft)
            if fails { throw Failure() }
        }
        model.onPosted = { posted = true }
        model.apply(configuration: nil, defaultVisibility: .public)
        model.text = "こんにちは"
        model.spoilerText = "隠した注意書き"

        await model.submit()
        #expect(model.errorMessage == "失敗しました")
        #expect(!posted)
        #expect(model.text == "こんにちは")

        fails = false
        await model.submit()
        #expect(posted)
        #expect(sent.count == 2)
        #expect(sent[0].idempotencyKey == sent[1].idempotencyKey)
        // 注意書きの欄を隠していれば、注意書きは送らない。
        #expect(sent.allSatisfy { $0.spoilerText.isEmpty })
    }

    @Test func replyTargetSwapsMentionsAndKeepsTypedText() throws {
        let model = ComposeModel(myAccountID: "1") { _ in }
        model.apply(configuration: nil, defaultVisibility: .public)
        model.text = "なるほど"

        model.setReplyTarget(try status(visibility: .public))
        #expect(model.text == "@bob なるほど")
        #expect(model.replyTo?.id == "10")

        model.setReplyTarget(nil)
        #expect(model.text == "なるほど")
        #expect(model.replyTo == nil)
    }

    /// 宛先を書き換えていたら、本文には手を付けず新しい宛先を前に足す。
    @Test func replyTargetKeepsEditedMentions() throws {
        let model = ComposeModel(replyTo: try status(visibility: .public), myAccountID: "1") { _ in }
        model.text = "@alice どうも"

        model.setReplyTarget(nil)

        #expect(model.text == "@alice どうも")
    }

    /// 新しい投稿で選んだ公開範囲を、フォロワー限定の投稿への返信に持ち込まない。
    @Test func replyTargetResetsChosenVisibility() throws {
        let model = ComposeModel(myAccountID: "1") { _ in }
        model.apply(configuration: nil, defaultVisibility: .unlisted)
        model.choose(.public)

        model.setReplyTarget(try status(visibility: .private))
        #expect(model.visibility == .private)

        model.setReplyTarget(nil)
        #expect(model.visibility == .unlisted)
    }

    @Test func replyTargetSwapsCopiedSpoilerButKeepsWrittenOne() throws {
        let target = try status(visibility: .public, spoilerText: "ネタバレ")
        let model = ComposeModel(myAccountID: "1") { _ in }

        model.setReplyTarget(target)
        #expect(model.showsSpoiler)
        #expect(model.spoilerText == "ネタバレ")

        model.setReplyTarget(nil)
        #expect(!model.showsSpoiler)

        model.showsSpoiler = true
        model.spoilerText = "自分の注意書き"
        model.setReplyTarget(target)
        #expect(model.spoilerText == "自分の注意書き")
    }

    @Test func postingResetsDraftForNextPost() async throws {
        var sent: [StatusDraft] = []
        var posted = false
        let model = ComposeModel(myAccountID: "1") { sent.append($0) }
        model.onPosted = { posted = true }
        model.apply(configuration: nil, defaultVisibility: .unlisted)
        model.setReplyTarget(try status(visibility: .private))
        model.text += "了解"

        await model.submit()

        #expect(posted)
        #expect(sent.first?.inReplyToID == "10")
        #expect(model.text.isEmpty)
        #expect(model.replyTo == nil)
        #expect(model.visibility == .unlisted)

        model.text = "了解"
        await model.submit()
        #expect(sent.count == 2)
        #expect(sent[0].idempotencyKey != sent[1].idempotencyKey)
    }

    /// 送信を待つ間に返信先を変えても、送っている下書きと食い違わないよう、変えさせない。
    @Test func replyTargetIsKeptWhilePosting() async throws {
        let original = try status(visibility: .public)
        let other = Status(id: "20", createdAt: .now, account: original.account, content: "", spoilerText: "", url: nil)
        var replyToDuringPost: Status.ID?
        var model: ComposeModel?
        let posting = ComposeModel(replyTo: original, myAccountID: "1") { _ in
            model?.setReplyTarget(other)
            replyToDuringPost = model?.replyTo?.id
        }
        model = posting
        posting.apply(configuration: nil, defaultVisibility: .public)
        posting.text += "了解"

        await posting.submit()

        #expect(replyToDuringPost == "10")
    }

    /// 応答だけが失われて失敗に見えた投稿に、同じ投稿の返信操作からもう一度送っても、二重に投稿しない。
    @Test func reselectingSameReplyTargetKeepsIdempotencyKey() async throws {
        let target = try status(visibility: .public)
        var sent: [StatusDraft] = []
        let model = ComposeModel(myAccountID: "1") { draft in
            sent.append(draft)
            throw Failure()
        }
        model.apply(configuration: nil, defaultVisibility: .public)
        model.setReplyTarget(target)
        model.text += "了解"

        await model.submit()
        model.setReplyTarget(target)
        await model.submit()

        #expect(model.text == "@bob 了解")
        #expect(sent.count == 2)
        #expect(sent[0].idempotencyKey == sent[1].idempotencyKey)
    }

    /// 同じ投稿を、元の投稿とブーストのように別の場所から選び直すと、下書きは保ったまま、札が指す先が選んだ方になる。
    @Test func reselectingSameStatusFromBoostPointsToBoost() throws {
        let original = try status(visibility: .public)
        let boost = Status(id: "30", createdAt: .now, account: original.account, content: "", spoilerText: "", url: nil, reblog: original)
        let model = ComposeModel(myAccountID: "1") { _ in }
        model.setReplyTarget(original)
        model.text += "了解"

        model.setReplyTarget(boost)

        #expect(model.replyTo?.id == "30")
        #expect(model.text == "@bob 了解")
    }
}
