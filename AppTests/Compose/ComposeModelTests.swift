import Foundation
import SciaCore
import SciaTesting
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
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
            content: "",
            spoilerText: spoilerText,
            url: nil,
            visibility: visibility
        )
    }

    @Test func defaultVisibilityAppliesUntilUserChooses() {
        let model = ComposeModel(tasks: TaskScope(), replyTo: nil, myAccountID: "1") { _ in }

        model.apply(configuration: nil, defaultVisibility: .unlisted, defaultSensitive: nil)
        #expect(model.visibility == .unlisted)

        model.choose(.private)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        #expect(model.visibility == .private)
    }

    /// 既定の公開範囲が分かるまでは、公開範囲を選んでいなければ投稿できない。既定より広い範囲で投稿してしまわないため。
    @Test func cannotPostUntilDefaultVisibilityIsKnownOrChosen() {
        let model = ComposeModel(tasks: TaskScope(), replyTo: nil, myAccountID: "1") { _ in }
        model.text = "こんにちは"
        #expect(!model.canPost)

        model.apply(configuration: nil, defaultVisibility: .private, defaultSensitive: nil)
        #expect(model.canPost)

        let chosen = ComposeModel(tasks: TaskScope(), replyTo: nil, myAccountID: "1") { _ in }
        chosen.text = "こんにちは"
        chosen.choose(.unlisted)
        #expect(chosen.canPost)
    }

    /// 既定の公開範囲を読めなかったときも、投稿できないままにはしない。
    @Test func canPostAfterDefaultsFailedToLoad() {
        let model = ComposeModel(tasks: TaskScope(), replyTo: nil, myAccountID: "1") { _ in }
        model.text = "こんにちは"

        model.apply(configuration: nil, defaultVisibility: nil, defaultSensitive: nil)

        #expect(model.canPost)
    }

    /// 送っている途中にバックグラウンドへ移っても送り終えられるよう、送っている間だけバックグラウンドの時間を頼む。
    @Test func holdsBackgroundTimeWhilePosting() async throws {
        let background = BackgroundTimeRecorder()
        let gate = Gate()
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", backgroundTime: background.request) { _ in
            try await gate.wait()
        }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        model.text = "こんにちは"

        let posting = Task { await model.submit() }
        try await waitUntil { gate.waiterCount == 1 }
        #expect(background.heldCount == 1)
        gate.open()
        await posting.value

        #expect(background.requestedNames == ["post status"])
        #expect(background.heldCount == 0)
    }

    /// ログアウトなどで投稿欄の持ち主を閉じたら、送っている途中の投稿も止め、頼んだバックグラウンドの時間を返す。
    @Test func closingSessionCancelsPosting() async throws {
        let background = BackgroundTimeRecorder()
        let gate = Gate()
        let session = TaskScope()
        let model = ComposeModel(tasks: session.child(), myAccountID: "1", backgroundTime: background.request) { _ in
            try await gate.wait()
        }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        model.text = "こんにちは"

        model.tasks.run { await model.submit() }
        try await waitUntil { gate.waiterCount == 1 }
        session.close()

        try await waitUntil { session.runningCount == 0 }
        #expect(gate.waiterCount == 0)
        #expect(!model.isPosting)
        #expect(background.heldCount == 0)
    }

    @Test func changedContentIsSentWithNewIdempotencyKey() async {
        var sent: [StatusDraft] = []
        let model = ComposeModel(tasks: TaskScope(), replyTo: nil, myAccountID: "1") { draft in
            sent.append(draft)
            throw Failure()
        }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
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
        let model = ComposeModel(tasks: TaskScope(), replyTo: try status(visibility: .public), myAccountID: "1") { _ in }

        model.apply(configuration: nil, defaultVisibility: .unlisted, defaultSensitive: nil)

        #expect(model.visibility == .unlisted)
        #expect(model.text == "@bob ")
    }

    @Test func appliesInstanceCharacterLimit() throws {
        let model = ComposeModel(tasks: TaskScope(), replyTo: nil, myAccountID: "1") { _ in }
        model.choose(.public)
        model.text = String(repeating: "あ", count: 600)
        #expect(!model.canPost)

        model.apply(configuration: InstanceConfiguration(streamingURL: try #require(URL(string: "wss://example.social")), maxCharacters: 1000, charactersReservedPerURL: 23, maxMediaAttachments: 4, mediaDescriptionLimit: 1500, supportedMediaTypes: nil, mediaLimits: .unknown), defaultVisibility: nil, defaultSensitive: nil)

        #expect(model.remainingCharacters == 400)
        #expect(model.canPost)
    }

    @Test func keepsDraftAndKeyWhenPostingFails() async {
        var sent: [StatusDraft] = []
        var posted = false
        var fails = true
        let model = ComposeModel(tasks: TaskScope(), replyTo: nil, myAccountID: "1") { draft in
            sent.append(draft)
            if fails { throw Failure() }
        }
        model.onPosted = { posted = true }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
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
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        model.text = "なるほど"

        model.setReplyTarget(try status(visibility: .public))
        #expect(model.text == "@bob なるほど")
        #expect(model.replyTo?.id == "10")

        model.setReplyTarget(nil)
        #expect(model.text == "なるほど")
        #expect(model.replyTo == nil)
    }

    /// 返信と引用は一緒に付けない。付け替えても、自分で書いた本文は残し、返信先から入れた宛先だけを外す。
    @Test func quoteTargetReplacesReplyAndKeepsTypedText() throws {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        model.setReplyTarget(try status(visibility: .public))
        model.text += "なるほど"

        model.setQuoteTarget(try status(visibility: .public))
        #expect(model.text == "なるほど")
        #expect(model.replyTo == nil)
        #expect(model.quoteTarget?.id == "10")

        model.setReplyTarget(try status(visibility: .public))
        #expect(model.text == "@bob なるほど")
        #expect(model.quoteTarget == nil)
    }

    /// フォロワー限定の投稿の引用は、フォロワー限定より広い範囲を選べない。引用をやめれば既定に戻る。
    @Test func quotingPrivateStatusLimitsVisibility() throws {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)

        model.setQuoteTarget(try status(visibility: .private))
        #expect(model.visibility == .private)
        #expect(!model.canChoose(.public))
        #expect(!model.canChoose(.unlisted))
        #expect(model.canChoose(.direct))

        model.choose(.public)
        #expect(model.visibility == .private)

        model.setQuoteTarget(nil)
        #expect(model.visibility == .public)
        #expect(model.canChoose(.public))
    }

    /// 引用すると投票の欄を外し、引用している間は足せない。Mastodonが一緒に付けられないため。
    @Test func quotingRemovesPollAndBlocksAddingOne() throws {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.addPoll()
        #expect(model.hasQuoteConflicts)

        model.setQuoteTarget(try status(visibility: .public))

        #expect(model.poll == nil)
        #expect(!model.canAddPoll)
        #expect(!model.canAttachMedia)
        model.addPoll()
        #expect(model.poll == nil)
    }

    /// 引用元を付けて送り、送れたら引用をやめた空の投稿欄に戻す。
    @Test func postsQuotedStatusIDAndResets() async throws {
        var sent: [StatusDraft] = []
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { sent.append($0) }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        model.setQuoteTarget(try status(visibility: .public))
        model.text = "見て"

        await model.submit()

        #expect(sent.map(\.quotedStatusID) == ["10"])
        #expect(sent.first?.inReplyToID == nil)
        #expect(model.quoteTarget == nil)
    }

    /// 宛先を書き換えていたら、本文には手を付けず新しい宛先を前に足す。
    @Test func replyTargetKeepsEditedMentions() throws {
        let model = ComposeModel(tasks: TaskScope(), replyTo: try status(visibility: .public), myAccountID: "1") { _ in }
        model.text = "@alice どうも"

        model.setReplyTarget(nil)

        #expect(model.text == "@alice どうも")
    }

    /// 新しい投稿で選んだ公開範囲を、フォロワー限定の投稿への返信に持ち込まない。
    @Test func replyTargetResetsChosenVisibility() throws {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.apply(configuration: nil, defaultVisibility: .unlisted, defaultSensitive: nil)
        model.choose(.public)

        model.setReplyTarget(try status(visibility: .private))
        #expect(model.visibility == .private)

        model.setReplyTarget(nil)
        #expect(model.visibility == .unlisted)
    }

    @Test func replyTargetSwapsCopiedSpoilerButKeepsWrittenOne() throws {
        let target = try status(visibility: .public, spoilerText: "ネタバレ")
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }

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

    /// 自分で開いた空の注意書きの欄は、返信先を替えても残す。添付があれば、閲覧注意を付けたままにするため。
    @Test func replyTargetKeepsSpoilerFieldOpenedByUser() throws {
        let target = try status(visibility: .public)
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.setReplyTarget(target)
        model.showsSpoiler = true

        model.setReplyTarget(nil)
        #expect(model.showsSpoiler)

        model.setReplyTarget(target)
        #expect(model.showsSpoiler)
    }

    /// 添付のない投稿では、空の注意書きの欄を開け閉めしても送る内容は変わらないので、同じIdempotency-Keyで送り直す。
    @Test func togglingEmptySpoilerWithoutMediaKeepsIdempotencyKey() async {
        var sent: [StatusDraft] = []
        let model = ComposeModel(tasks: TaskScope(), replyTo: nil, myAccountID: "1") { draft in
            sent.append(draft)
            throw Failure()
        }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        model.text = "本文"

        await model.submit()
        model.showsSpoiler = true
        await model.submit()

        #expect(sent.count == 2)
        #expect(sent[0].idempotencyKey == sent[1].idempotencyKey)
    }

    @Test func postingResetsDraftForNextPost() async throws {
        var sent: [StatusDraft] = []
        var posted = false
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { sent.append($0) }
        model.onPosted = { posted = true }
        model.apply(configuration: nil, defaultVisibility: .unlisted, defaultSensitive: nil)
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
        let other = Status(id: "20", createdAt: Date(timeIntervalSince1970: 0), account: original.account, content: "", spoilerText: "", url: nil)
        var replyToDuringPost: Status.ID?
        var model: ComposeModel?
        let posting = ComposeModel(tasks: TaskScope(), replyTo: original, myAccountID: "1") { _ in
            model?.setReplyTarget(other)
            replyToDuringPost = model?.replyTo?.id
        }
        model = posting
        posting.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        posting.text += "了解"

        await posting.submit()

        #expect(replyToDuringPost == "10")
    }

    /// 応答だけが失われて失敗に見えた投稿に、同じ投稿の返信操作からもう一度送っても、二重に投稿しない。
    @Test func reselectingSameReplyTargetKeepsIdempotencyKey() async throws {
        let target = try status(visibility: .public)
        var sent: [StatusDraft] = []
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { draft in
            sent.append(draft)
            throw Failure()
        }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        model.setReplyTarget(target)
        model.text += "了解"

        await model.submit()
        model.setReplyTarget(target)
        await model.submit()

        #expect(model.text == "@bob 了解")
        #expect(sent.count == 2)
        #expect(sent[0].idempotencyKey == sent[1].idempotencyKey)
    }

    /// 同じ投稿を、元の投稿とブーストのように別の場所から選び直すと、下書きは保ったまま、ラベルが指す先が選んだ方になる。
    @Test func reselectingSameStatusFromBoostPointsToBoost() throws {
        let original = try status(visibility: .public)
        let boost = Status(id: "30", createdAt: Date(timeIntervalSince1970: 0), account: original.account, content: "", spoilerText: "", url: nil, reblog: original)
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1") { _ in }
        model.setReplyTarget(original)
        model.text += "了解"

        model.setReplyTarget(boost)

        #expect(model.replyTo?.id == "30")
        #expect(model.text == "@bob 了解")
    }
}
