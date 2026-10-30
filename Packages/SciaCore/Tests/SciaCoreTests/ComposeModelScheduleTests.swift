import Foundation
@testable import SciaCore
import SciaTesting
import Testing

/// 投稿欄の予約と、予約した投稿の書き直し。決まりはdocs/compose.mdの「予約投稿」にある。
@MainActor
struct ComposeModelScheduleTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private func makeModel(media: ComposeMediaService = .unavailable, appliesDefaults: Bool = true, post: @escaping (StatusDraft) async throws -> Void) -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: media, post: post)
        model.now = { Self.now }
        model.calendar = Self.utc
        if appliesDefaults {
            model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        }
        return model
    }

    private func scheduled(text: String = "予約した本文", inReplyToID: String? = nil, quotedStatusID: String? = nil) -> ScheduledStatus {
        ScheduledStatus(
            id: "70",
            scheduledAt: Self.now.addingTimeInterval(3 * 60 * 60),
            params: ScheduledStatus.Params(text: text, visibility: .unlisted, inReplyToID: inReplyToID, quotedStatusID: quotedStatusID)
        )
    }

    /// 予約を足すと、1時間より先のいちばん近い正時を日時にし、送る下書きに日時を入れる。外すと、すぐ投稿する下書きに戻る。
    @Test func scheduleIsSentWithDraftUntilRemoved() async {
        var sent: [StatusDraft] = []
        let model = makeModel { sent.append($0) }
        model.text = "おはよう"

        model.addSchedule()
        let expected = ScheduledPosting.defaultDate(now: Self.now, calendar: Self.utc)
        #expect(model.scheduledAt == expected)
        await model.submit()
        #expect(sent.map(\.scheduledAt) == [expected])
        // 予約できたら下書きを空に戻し、予約も外す。
        #expect(model.scheduledAt == nil)
        #expect(model.text.isEmpty)

        model.text = "すぐ"
        model.addSchedule()
        model.removeSchedule()
        await model.submit()
        #expect(sent.last?.scheduledAt == nil)
    }

    /// 日時が今から5分より後でなければ、送らずに知らせ、下書きを残す。サーバーは過去の日時をすぐ投稿するため。
    @Test func scheduleWithinLeadTimeIsNotSent() async {
        var sent: [StatusDraft] = []
        let model = makeModel { sent.append($0) }
        model.text = "おはよう"
        model.addSchedule()

        model.setScheduledDate(Self.now.addingTimeInterval(5 * 60))
        await model.submit()

        #expect(sent.isEmpty)
        #expect(model.errorMessage == "予約の日時は、今から5分より後にしてください。")
        #expect(model.text == "おはよう")
        #expect(model.scheduledAt != nil)
    }

    /// 編集では予約を足せない。Mastodonは編集の予約を受け付けないため。
    @Test func cannotScheduleWhileEditing() throws {
        let model = makeModel { _ in }
        let status = Status(
            id: "10",
            createdAt: Self.now,
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: URL(string: "https://example.social/a.png")),
            content: "",
            spoilerText: "",
            url: nil,
            visibility: .public
        )
        model.addSchedule()
        model.beginEditing(status, source: StatusSource(id: "10", text: "元", spoilerText: ""), now: Self.now)

        #expect(!model.canSchedule)
        #expect(model.scheduledAt == nil)
        model.addSchedule()
        #expect(model.scheduledAt == nil)
    }

    /// 送る内容の日時を変えたら、別の投稿として新しい`Idempotency-Key`にする。応答だけを失った予約と取り違えないため。
    @Test func changingDateRenewsIdempotencyKey() async {
        var sent: [StatusDraft] = []
        var fails = true
        let model = makeModel { draft in
            sent.append(draft)
            if fails { throw URLError(.timedOut) }
        }
        model.text = "おはよう"
        model.addSchedule()
        await model.submit()
        await model.submit()
        model.setScheduledDate(Self.now.addingTimeInterval(24 * 60 * 60))
        fails = false
        await model.submit()

        #expect(sent.count == 3)
        #expect(sent[0].idempotencyKey == sent[1].idempotencyKey)
        #expect(sent[1].idempotencyKey != sent[2].idempotencyKey)
    }

    /// 書き直しでは、予約した内容と日時を戻し、送れたら元の予約のIDを渡す。元の予約は、送れるまで取り消させない。
    @Test func rewriteRestoresAndReportsOriginalAfterPosting() async {
        var sent: [StatusDraft] = []
        var rewritten: [ScheduledStatus.ID] = []
        var fails = true
        let model = makeModel { draft in
            sent.append(draft)
            if fails { throw URLError(.timedOut) }
        }
        model.onScheduleRewritten = { rewritten.append($0) }
        let scheduled = scheduled(inReplyToID: "5")

        model.beginRewriting(scheduled)
        #expect(model.text == "予約した本文")
        #expect(model.visibility == .unlisted)
        #expect(model.scheduledAt == scheduled.scheduledAt)
        #expect(model.rewriteChipTitle == "予約した返信を書き直し中")
        #expect(model.hasWrittenContent)

        await model.submit()
        #expect(rewritten.isEmpty)

        fails = false
        model.text = "書き直した本文"
        await model.submit()
        #expect(rewritten == ["70"])
        #expect(sent.last?.text == "書き直した本文")
        #expect(sent.last?.inReplyToID == "5")
        #expect(model.rewritingSchedule == nil)
    }

    /// 書き直しをやめたら、元の予約は取り消させない。
    @Test func resetStopsRewritingWithoutCancelling() async {
        var rewritten: [ScheduledStatus.ID] = []
        let model = makeModel { _ in }
        model.onScheduleRewritten = { rewritten.append($0) }
        model.beginRewriting(scheduled())

        model.reset()
        model.text = "別の投稿"
        await model.submit()

        #expect(rewritten.isEmpty)
        #expect(model.rewriteChipTitle == nil)
    }

    /// 引用の予約を書き直している間は、引用元の投稿を持たなくても、添付と投票を足させない。Mastodonは引用と一緒に付けられないため。
    @Test func rewritingQuoteBlocksMediaAndPoll() {
        let model = makeModel { _ in }
        model.beginRewriting(scheduled(quotedStatusID: "9"))

        #expect(model.isQuoting)
        #expect(!model.canAddPoll)
        #expect(!model.canPasteMedia)
        #expect(model.rewriteChipTitle == "予約した引用を書き直し中")
    }

    /// 公開範囲を送っていない予約は、既定の公開範囲が届くのを待ってから、その範囲で送る。届く前に公開で送ってしまわないため。
    @Test func rewriteWithoutVisibilityWaitsForDefault() {
        let model = makeModel(appliesDefaults: false) { _ in }
        let scheduled = ScheduledStatus(id: "71", scheduledAt: Self.now.addingTimeInterval(3 * 60 * 60), params: ScheduledStatus.Params(text: "既定の範囲"))

        model.beginRewriting(scheduled)
        #expect(!model.canPost)

        model.apply(configuration: nil, defaultVisibility: .private, defaultSensitive: nil)
        #expect(model.visibility == .private)
        #expect(model.canPost)
    }

    /// 予約から戻した添付は、サーバーのメディアで描き、代替テキストを送れなかったら、ほかの添付と同じく失敗として残す。
    @Test func restoredAttachmentKeepsDescriptionFailure() async throws {
        let gate = Gate()
        let media = ComposeMediaService(
            upload: { _ in throw CancellationError() },
            waitUntilProcessed: { _ in throw CancellationError() },
            updateDescription: { _, _ in
                try await gate.wait()
                throw URLError(.timedOut)
            },
            makeThumbnail: { _ in nil },
            unprocessableImageTypes: { [] },
            recordUnprocessableImageType: { _ in },
            preparation: { .keepsOriginal }
        )
        let model = makeModel(media: media) { _ in }
        let attachment = MediaAttachment(id: "100", type: .image, url: URL(string: "https://example.social/100.jpg"), previewUrl: nil, description: "前の説明")
        let scheduled = ScheduledStatus(id: "72", scheduledAt: Self.now.addingTimeInterval(3 * 60 * 60), params: ScheduledStatus.Params(text: "", visibility: .public), mediaAttachments: [attachment])
        model.beginRewriting(scheduled)
        let id = try #require(model.attachments.first?.id)
        #expect(model.attachmentStatus(of: id) == .ready)
        #expect(model.localMedia[id]?.file == nil)

        model.setDescription("新しい説明", of: id)
        #expect(model.attachmentStatus(of: id) == .sendingDescription)
        gate.open()
        try await waitUntil { model.attachmentStatus(of: id) != .sendingDescription }

        #expect(model.attachmentStatus(of: id) == .descriptionFailed)
        #expect(!model.canPost)
    }
}
