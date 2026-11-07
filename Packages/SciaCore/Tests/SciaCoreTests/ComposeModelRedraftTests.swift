import Foundation
@_spi(FailureDisplay) @testable import SciaCore
import SciaTesting
import Synchronization
import Testing

/// 自分の投稿を削除して書き直す。決まりはdocs/compose.mdの「自分の投稿を削除して書き直す」にある。
@MainActor
struct ComposeModelRedraftTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let source = StatusSource(id: "10", text: "元の本文 #tag", spoilerText: "")

    /// サーバーへの送信の順番を記録する。添付が外れるのを待つ処理は同時に走るので、ロックで守る。
    private final class Events: Sendable {
        private let state = Mutex<[String]>([])
        var all: [String] { state.withLock { $0 } }
        func append(_ event: String) { state.withLock { $0.append(event) } }
    }

    private final class Counter: Sendable {
        private let state = Mutex(0)
        func next() -> Int {
            state.withLock { count in
                count += 1
                return count
            }
        }
    }

    nonisolated private static func attachment(_ id: String, description: String = "元の説明") -> MediaAttachment {
        MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/\(id).jpg"), previewUrl: nil, description: description)
    }

    private func status(
        media: [MediaAttachment] = [],
        visibility: Status.Visibility = .unlisted,
        inReplyToID: String? = nil,
        quote: Quote? = nil,
        poll: Poll? = nil,
        pinned: Bool = false
    ) -> Status {
        Status(
            id: "10",
            createdAt: Self.now,
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: URL(string: "https://example.social/a.png")),
            content: "<p>元の本文 <a href=\"https://example.social/tags/tag\">#tag</a></p>",
            spoilerText: "",
            language: "en",
            url: nil,
            mediaAttachments: media,
            sensitive: !media.isEmpty,
            visibility: visibility,
            inReplyToId: inReplyToID,
            poll: poll,
            quote: quote,
            pinned: pinned
        )
    }

    private func redraftService(
        _ events: Events,
        delete: @escaping @Sendable () throws -> Void = {},
        release: @escaping @Sendable (String) throws -> MediaAttachment
    ) -> ComposeRedraftService {
        ComposeRedraftService(
            deleteStatus: { id in
                events.append("delete \(id)")
                try delete()
            },
            waitUntilReleased: { id in
                events.append("release \(id)")
                return try release(id)
            }
        )
    }

    private func mediaService(_ events: Events) -> ComposeMediaService {
        ComposeMediaService(
            upload: { _ in throw CancellationError() },
            waitUntilProcessed: { _ in throw CancellationError() },
            updateDescription: { id, description in
                events.append("describe \(id) \(description)")
                return MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/\(id).jpg"), previewUrl: nil, description: description)
            },
            makeThumbnail: { _ in nil },
            unprocessableImageTypes: { [] },
            recordUnprocessableImageType: { _ in },
            preparation: { .keepsOriginal }
        )
    }

    private func makeModel(_ events: Events, redraft: ComposeRedraftService, post: @escaping (StatusDraft) async throws -> Void) -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", media: mediaService(events), redraft: redraft, post: post)
        model.now = { Self.now }
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        return model
    }

    /// 本文と注意書きはソースから、ほかは元の投稿から戻し、元の投稿は送るまで削除しない。公開範囲は選び直せる。
    @Test func beginRestoresOriginalWithoutDeleting() throws {
        let events = Events()
        let model = makeModel(events, redraft: redraftService(events) { Self.attachment($0) }) { _ in }

        #expect(model.beginRedrafting(status(media: [Self.attachment("100")], inReplyToID: "5"), source: Self.source))

        #expect(model.text == "元の本文 #tag")
        #expect(model.visibility == .unlisted)
        #expect(model.language == "en")
        #expect(model.isReplying)
        // 元の投稿で添付を閲覧注意にしていれば、注意書きが空でも欄を出す。
        #expect(model.showsSpoiler)
        let restored = try #require(model.attachments.first)
        #expect(restored.isHeldByRedraftedStatus)
        #expect(model.attachmentStatus(of: restored.id) == .ready)
        #expect(model.redraftChipTitle == "返信を削除して書き直し中")
        #expect(model.hasWrittenContent)
        #expect(model.canPost)
        #expect(model.canChoose(.public))
        #expect(events.all.isEmpty)

        // やめても、元の投稿は残る。
        model.reset()
        #expect(model.redraft == nil)
        #expect(events.all.isEmpty)
    }

    /// 送ると、元の投稿を削除し、元の添付が外れるのを待ってから、書き換えた代替テキストを送り、投稿する。
    @Test func submitDeletesThenReattachesMedia() async throws {
        let events = Events()
        var deleted: [Status.ID] = []
        let model = makeModel(events, redraft: redraftService(events) { Self.attachment($0) }) { draft in
            events.append("post \(draft.mediaIDs ?? [])")
        }
        model.onRedraftDeleted = { deleted.append($0) }
        model.beginRedrafting(status(media: [Self.attachment("100"), Self.attachment("101")]), source: Self.source)
        let first = try #require(model.attachments.first?.id)
        // 元の投稿に付いている間は、代替テキストを送らない。サーバーが断るため。
        model.setDescription("書き直した説明", of: first)
        #expect(model.attachmentStatus(of: first) == .ready)
        #expect(events.all.isEmpty)

        await model.submit()

        // 添付が外れるのは同時に待つので、順番は決まらない。
        let all = events.all
        #expect(all.first == "delete 10")
        #expect(Set(all[1...2]) == ["release 100", "release 101"])
        #expect(Array(all.dropFirst(3)) == ["describe 100 書き直した説明", "post [\"100\", \"101\"]"])
        #expect(deleted == ["10"])
        #expect(model.redraft == nil)
        #expect(model.text.isEmpty)
    }

    /// 書き直している間に外した添付は待たない。通報された投稿のように、いつまでも外れない添付を外せば送れるようにするため。
    @Test func removedAttachmentIsNotAwaited() async throws {
        let events = Events()
        let model = makeModel(events, redraft: redraftService(events) { _ in throw RedraftMediaError.notReleased }) { draft in
            events.append("post \(draft.mediaIDs ?? [])")
        }
        model.beginRedrafting(status(media: [Self.attachment("100")]), source: Self.source)
        model.removeAttachment(try #require(model.attachments.first?.id), pickerIsOpen: false)

        await model.submit()

        #expect(events.all == ["delete 10", "post []"])
    }

    /// サーバーが削除を断ったら（4xx）、元の投稿は残っているので、送らずに知らせ、書き直しを続けられるようにする。
    @Test func refusedDeletionKeepsOriginal() async {
        let events = Events()
        let model = makeModel(events, redraft: redraftService(events, delete: { throw MastodonAPIError(statusCode: 403, message: "") }) { Self.attachment($0) }) { _ in
            events.append("post")
        }
        model.beginRedrafting(status(), source: Self.source)

        await model.submit()

        #expect(events.all == ["delete 10"])
        #expect(model.redraft?.deletion == .pending)
        #expect(model.postError?.text.hasPrefix("元の投稿を削除できなかったため") == true)
        #expect(Confirmation.discardingRedraft(draft: model) == nil)
    }

    /// 応答を受け取れず、削除が届いたか分からなければ、やめる前に確かめ、送り直すときは削除から送り直す。404なら届いていたものとして続ける。
    @Test func uncertainDeletionIsRetried() async {
        let events = Events()
        let attempts = Counter()
        let model = makeModel(events, redraft: redraftService(events, delete: {
            let attempt = attempts.next()
            throw attempt == 1 ? URLError(.timedOut) as any Error : MastodonAPIError(statusCode: 404, message: "Record not found")
        }) { Self.attachment($0) }) { _ in
            events.append("post")
        }
        model.beginRedrafting(status(), source: Self.source)

        await model.submit()
        #expect(model.redraft?.deletion == .uncertain)
        #expect(model.postError?.text.hasPrefix("元の投稿を削除できたか分からないため") == true)
        #expect(Confirmation.discardingRedraft(draft: model) != nil)
        #expect(events.all == ["delete 10"])

        model.postError = nil
        await model.submit()
        #expect(events.all == ["delete 10", "delete 10", "post"])
        #expect(model.redraft == nil)
    }

    /// 5xxは届いたか分からないものとして扱う。Mastodonは投稿を消してから応答を返すので、プロキシの502や504でも消えていることがあるため。
    @Test(arguments: [500, 502, 504]) func serverErrorMakesDeletionUncertain(statusCode: Int) async {
        let events = Events()
        let model = makeModel(events, redraft: redraftService(events, delete: { throw MastodonAPIError(statusCode: statusCode, message: "") }) { Self.attachment($0) }) { _ in
            events.append("post")
        }
        model.beginRedrafting(status(), source: Self.source)

        await model.submit()

        #expect(model.redraft?.deletion == .uncertain)
        #expect(Confirmation.discardingRedraft(draft: model) != nil)
        #expect(events.all == ["delete 10"])
    }

    /// ほかの端末で元の投稿が消えたと分かったら、やめる前に確かめ、送るときは削除せずに続ける。
    @Test func deletionLearnedElsewhereSkipsDeleting() async {
        let events = Events()
        let model = makeModel(events, redraft: redraftService(events) { Self.attachment($0) }) { _ in
            events.append("post")
        }
        model.beginRedrafting(status(), source: Self.source)

        model.redraftedStatusWasDeleted("99", stopsRedrafting: false)
        #expect(model.redraft?.deletion == .pending)
        model.redraftedStatusWasDeleted("10", stopsRedrafting: false)
        #expect(model.redraftChipTitle == "削除した投稿を書き直し中")
        #expect(Confirmation.discardingRedraft(draft: model) != nil)

        await model.submit()
        #expect(events.all == ["post"])
    }

    /// この端末の「削除」で元の投稿を消したら、書き直しをやめる。送っている途中なら、送るのをやめてから空に戻す。
    @Test func deletingOriginalStopsRedrafting() async throws {
        let events = Events()
        let gate = Gate()
        let service = ComposeRedraftService(
            deleteStatus: { _ in
                events.append("delete")
                try await gate.wait()
                throw MastodonAPIError(statusCode: 404, message: "Record not found")
            },
            waitUntilReleased: { id in Self.attachment(id) }
        )
        let model = makeModel(events, redraft: service) { _ in events.append("post") }

        model.beginRedrafting(status(), source: Self.source)
        model.redraftedStatusWasDeleted("10", stopsRedrafting: true)
        #expect(model.redraft == nil)

        model.beginRedrafting(status(), source: Self.source)
        let submitting = Task { await model.submit() }
        try await waitUntil { events.all == ["delete"] }
        model.redraftedStatusWasDeleted("10", stopsRedrafting: true)
        gate.open()
        await submitting.value

        #expect(events.all == ["delete"])
        #expect(model.redraft == nil)
        #expect(model.text.isEmpty)
        #expect(!model.isPosting)
    }

    /// 削除したあとに投稿が断られたら、下書きを残し、元の投稿はもうないことをラベルに出す。
    /// 送り直すときは削除し直さず、一度外れた添付も待ち直さない。投稿が届いて応答だけを失っていれば、添付はもう新しい投稿に付いているため。
    @Test func failedPostAfterDeletionResumesWithoutDeletingAgain() async throws {
        let events = Events()
        var fails = true
        var sentKeys: [String] = []
        let model = makeModel(events, redraft: redraftService(events) { Self.attachment($0) }) { draft in
            events.append("post")
            sentKeys.append(draft.idempotencyKey)
            if fails { throw URLError(.timedOut) }
        }
        model.beginRedrafting(status(media: [Self.attachment("100")]), source: Self.source)

        await model.submit()
        #expect(model.redraft?.deletion == .done)
        #expect(model.redraftChipTitle == "削除した投稿を書き直し中")
        #expect(Confirmation.discardingRedraft(draft: model) != nil)
        #expect(model.attachments.first?.isHeldByRedraftedStatus == false)

        fails = false
        model.postError = nil
        await model.submit()
        #expect(events.all == ["delete 10", "release 100", "post", "post"])
        // 同じ下書きなので、届いていた投稿をサーバーに返させるよう、同じキーで送り直す。
        #expect(Set(sentKeys).count == 1)
        #expect(model.redraft == nil)
    }

    /// 元の添付が外れないまま時間切れになったら、送らずに知らせ、その添付を失敗として出す。送り直すと、待ち直す。
    @Test func unreleasedMediaFailsAndIsAwaitedAgain() async throws {
        let events = Events()
        let releases = Counter()
        let model = makeModel(events, redraft: redraftService(events) { id in
            guard releases.next() > 1 else { throw RedraftMediaError.notReleased }
            return Self.attachment(id)
        }) { _ in
            events.append("post")
        }
        model.beginRedrafting(status(media: [Self.attachment("100")]), source: Self.source)
        let id = try #require(model.attachments.first?.id)

        await model.submit()
        #expect(model.attachmentStatus(of: id) == .failed)
        #expect(model.postError?.text.hasPrefix("元の投稿を削除しましたが、投稿しませんでした。") == true)
        #expect(events.all == ["delete 10", "release 100"])

        model.postError = nil
        await model.submit()
        #expect(events.all == ["delete 10", "release 100", "release 100", "post"])
    }

    /// 元の投稿の添付が外れるのを待つ間は、メディアの準備を待つときと同じく、待つのをやめられる。やめても元の投稿は削除したまま。
    @Test func waitingForReleaseCanBeCancelled() async throws {
        let events = Events()
        let gate = Gate()
        let service = ComposeRedraftService(
            deleteStatus: { _ in events.append("delete") },
            waitUntilReleased: { id in
                try await gate.wait()
                return MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/\(id).jpg"), previewUrl: nil)
            }
        )
        let model = makeModel(events, redraft: service) { _ in events.append("post") }
        model.beginRedrafting(status(media: [Self.attachment("100")]), source: Self.source)
        let id = try #require(model.attachments.first?.id)

        let submitting = Task { await model.submit() }
        try await waitUntil { model.isWaitingForMedia && model.redraft?.deletion == .done }
        #expect(model.attachmentStatus(of: id) == .processing)
        model.cancelWaitingForMedia()
        await submitting.value

        #expect(events.all == ["delete"])
        #expect(model.redraftChipTitle == "削除した投稿を書き直し中")
        // やめても待つことは続け、外れたら次に送るときに待たずに済む。
        gate.open()
        try await waitUntil { model.attachments.first?.isHeldByRedraftedStatus == false }
    }

    /// 投票は選択肢と選び方と票数を隠すかを戻し、締め切りは元の投票の長さにいちばん近い選択肢にする。
    @Test func pollRestoresSettingsAndNearestDuration() throws {
        let poll = Poll(
            id: "p",
            expiresAt: Self.now.addingTimeInterval(3 * 86_400 - 600),
            expired: false,
            multiple: true,
            votesCount: 3,
            options: [.init(title: "はい", votesCount: nil), .init(title: "いいえ", votesCount: nil)]
        )
        let draft = StatusDraft.redraft(of: status(poll: poll), source: Self.source)

        let restored = try #require(draft.poll)
        #expect(restored.filledOptions == ["はい", "いいえ"])
        #expect(restored.multiple)
        #expect(restored.hidesTotals)
        #expect(restored.expiresIn == 259_200)
    }

    /// 締め切った投票は、票数を隠していたか見分けられないので、隠さないにする。
    @Test func expiredPollShowsTotals() throws {
        let poll = Poll(id: "p", expiresAt: Self.now.addingTimeInterval(300), expired: true, multiple: false, votesCount: 1, options: [.init(title: "a", votesCount: 1), .init(title: "b", votesCount: 0)])
        let draft = StatusDraft.redraft(of: status(poll: poll), source: Self.source)

        #expect(draft.poll?.hidesTotals == false)
        #expect(draft.poll?.expiresIn == 300)
    }

    /// 引用元はIDだけを持つ。サーバー独自の公開範囲は、どこまで届くか分からないためフォロワー限定にする。
    @Test func quoteAndUnknownVisibility() {
        let draft = StatusDraft.redraft(of: status(visibility: .other("local"), quote: Quote(state: "accepted", quotedStatusID: "30")), source: Self.source)

        #expect(draft.quotedStatusID == "30")
        #expect(draft.visibility == .private)
    }

    /// 始める前の確認には、送ると削除すること、なくなるものを書く。投票の票と固定は、当てはまるときだけ書く。
    @Test func confirmationListsWhatIsLost() {
        let events = Events()
        let model = makeModel(events, redraft: redraftService(events) { Self.attachment($0) }) { _ in }
        let poll = Poll(id: "p", expiresAt: nil, expired: false, multiple: false, votesCount: 0, options: [])

        let plain = Confirmation.redrafting(status(), draft: model)
        #expect(plain.title == "削除して書き直しますか？")
        #expect(plain.message == "書き直した投稿を送ると元の投稿を削除します。お気に入り、ブーストはなくなり、元の投稿への返信はつながりを失います。")

        model.text = "書きかけ"
        let full = Confirmation.redrafting(status(poll: poll, pinned: true), draft: model)
        #expect(full.title == "下書きを破棄して書き直しますか？")
        #expect(full.message == "書きかけの下書きは破棄されます。\n書き直した投稿を送ると元の投稿を削除します。お気に入り、ブースト、投票の票はなくなり、元の投稿への返信はつながりを失います。\nプロフィールへの固定も外れます。")
    }

    /// 書き直している途中で返信か引用を選んだら、書き直しをやめてよいか確かめる。返信先と引用元は変えられないため。
    @Test func leavingRedraftIsConfirmed() {
        let events = Events()
        let model = makeModel(events, redraft: redraftService(events) { Self.attachment($0) }) { _ in }
        #expect(Confirmation.leavingEdit(starting: "返信", draft: model) == nil)

        model.beginRedrafting(status(), source: Self.source)

        let confirmation = Confirmation.leavingEdit(starting: "返信", draft: model)
        #expect(confirmation?.title == "書き直しをやめて返信しますか？")
        #expect(confirmation?.message == "書き直し中の内容は破棄されます。元の投稿は残ります。")
    }
}
