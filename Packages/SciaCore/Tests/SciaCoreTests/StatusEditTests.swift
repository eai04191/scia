import Foundation
import Testing
@testable import SciaCore

struct StatusEditTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(_ id: String) -> Account {
        Account(id: id, username: "alice", acct: "alice", displayName: "", avatar: URL(string: "https://example.social/a.png"))
    }

    private func media(_ id: String, description: String? = nil) -> MediaAttachment {
        MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/\(id).png"), previewUrl: nil, description: description)
    }

    private func poll(expiresIn seconds: TimeInterval?, expired: Bool = false, votes: Int? = 3) -> Poll {
        Poll(
            id: "50",
            expiresAt: seconds.map { Self.now.addingTimeInterval($0) },
            expired: expired,
            multiple: true,
            votesCount: votes ?? 0,
            options: [Poll.Option(title: "はい", votesCount: votes), Poll.Option(title: "いいえ", votesCount: votes.map { _ in 0 })]
        )
    }

    private func status(
        accountID: String = "1",
        spoilerText: String = "",
        media: [MediaAttachment] = [],
        sensitive: Bool = false,
        poll: Poll? = nil,
        reblog: Status? = nil,
        language: String? = nil
    ) -> Status {
        Status(
            id: "10",
            createdAt: Self.now,
            account: account(accountID),
            content: "<p>本文</p>",
            spoilerText: spoilerText,
            language: language,
            url: nil,
            mediaAttachments: media,
            sensitive: sensitive,
            visibility: .private,
            inReplyToId: "9",
            poll: poll,
            reblog: reblog
        )
    }

    private func body(_ draft: StatusDraft) throws -> StatusRequestBody {
        let editing = try #require(draft.editing)
        return try #require(draft.editBody(poll: editing.poll, now: Self.now))
    }

    // MARK: - 編集の下書き

    /// 本文と注意書きはHTMLではなく、書いたときのソースから入れる。公開範囲と返信先は元の投稿のまま持つ。
    @Test func editDraftStartsFromSource() throws {
        let draft = try #require(StatusDraft.edit(of: status(spoilerText: "注意"), source: StatusSource(id: "10", text: "@bob 本文", spoilerText: "注意"), now: Self.now))

        #expect(draft.text == "@bob 本文")
        #expect(draft.spoilerText == "注意")
        #expect(draft.hasSpoiler)
        #expect(draft.visibility == .private)
        #expect(draft.inReplyToID == "9")
        #expect(draft.editing == StatusEditTarget(statusID: "10", poll: nil))
    }

    /// 言語は元の投稿のまま始め、送り直す。言語の分からない投稿では送らず、サーバーに今の言語を残させる。
    @Test(arguments: ["en", nil] as [String?])
    func editKeepsLanguage(language: String?) throws {
        let draft = try #require(StatusDraft.edit(of: status(language: language), source: StatusSource(id: "10", text: "本文", spoilerText: ""), now: Self.now))

        #expect(draft.language == language)
        #expect(try body(draft).language == language)
    }

    /// 注意書きなしで添付だけ閲覧注意にしていた投稿は、空の注意書きの欄を出して閲覧注意を保つ。
    @Test func editDraftKeepsSensitiveMediaWithEmptySpoiler() throws {
        let draft = try #require(StatusDraft.edit(of: status(media: [media("100")], sensitive: true), source: StatusSource(id: "10", text: "", spoilerText: ""), now: Self.now))

        #expect(draft.hasSpoiler)
        #expect(draft.sensitive)
    }

    /// 投稿に付いている添付は、代替テキストを書き換えても`PUT /api/v1/media/:id`では送らず、送れる状態のまま並べる。
    @Test func attachedMediaIsReadyWithChangedDescription() throws {
        var draft = try #require(StatusDraft.edit(of: status(media: [media("100", description: "猫"), media("101")]), source: StatusSource(id: "10", text: "", spoilerText: ""), now: Self.now))
        #expect(draft.attachments.map(\.description) == ["猫", ""])

        draft.attachments[1].description = "犬"

        #expect(!draft.attachments[1].needsDescriptionUpdate)
        #expect(draft.mediaIDs == ["100", "101"])
        #expect(draft.changedAttachedDescriptions.map(\.id) == ["101"])
        #expect(draft.changedAttachedDescriptions.map(\.description) == ["犬"])
    }

    // MARK: - 送る本文

    /// 送ったが届いたか分からない代替テキストは、元と同じ値に戻しても送る。応答だけを失い、サーバーが書き換えた値のままのことがあるため。
    @Test func unconfirmedDescriptionIsSentEvenWhenRestored() throws {
        var draft = try #require(StatusDraft.edit(of: status(media: [media("100", description: "猫")]), source: StatusSource(id: "10", text: "", spoilerText: ""), now: Self.now))
        draft.attachments[0].hasUnconfirmedDescription = true

        #expect(try body(draft).mediaAttributes == [StatusRequestBody.MediaAttribute(id: "100", description: "猫")])
    }

    /// 変えていない添付、注意書き、閲覧注意も毎回送る。送らなければサーバーが消すため。公開範囲と返信先は送らない。
    @Test func bodySendsEveryEditableField() throws {
        let draft = try #require(StatusDraft.edit(of: status(media: [media("100", description: "猫")], sensitive: true), source: StatusSource(id: "10", text: "本文", spoilerText: ""), now: Self.now))

        #expect(try body(draft) == StatusRequestBody(status: "本文", spoilerText: "", sensitive: true, mediaIDs: ["100"]))
    }

    /// 書き換えた代替テキストは、要素ごとにidを先に置いて送る。新しく足した添付は、アップロードの流れで送り済みなので含めない。
    @Test func bodySendsChangedDescriptionsOfAttachedMedia() throws {
        var draft = try #require(StatusDraft.edit(of: status(media: [media("100", description: "猫"), media("101")]), source: StatusSource(id: "10", text: "", spoilerText: ""), now: Self.now))
        draft.attachments[0].description = "三毛猫"
        draft.attachments[1].description = "犬"
        draft.attachments.append(DraftAttachment(state: .uploaded(media("102", description: "鳥")), description: "鳥"))

        #expect(try body(draft).mediaAttributes == [
            StatusRequestBody.MediaAttribute(id: "100", description: "三毛猫"),
            StatusRequestBody.MediaAttribute(id: "101", description: "犬"),
        ])
        #expect(try body(draft).mediaIDs == ["100", "101", "102"])
    }

    /// 添付を全部外したら`media_ids`を送らない。送らなければ添付は外れる。
    @Test func bodyOmitsMediaIDsWhenAllRemoved() throws {
        var draft = try #require(StatusDraft.edit(of: status(media: [media("100")]), source: StatusSource(id: "10", text: "本文", spoilerText: ""), now: Self.now))
        draft.attachments.removeAll()

        #expect(try body(draft).mediaIDs == nil)
        #expect(try body(draft).mediaAttributes == nil)
    }

    /// 投票は、選択肢、複数選べるか、票数を隠すかを元のまま、残りの時間で送り直す。
    @Test func bodyResendsPollAsIs() throws {
        let draft = try #require(StatusDraft.edit(of: status(poll: poll(expiresIn: 3600.4)), source: StatusSource(id: "10", text: "どっち？", spoilerText: ""), now: Self.now))

        #expect(try body(draft).poll == StatusRequestBody.Poll(options: ["はい", "いいえ"], expiresIn: 3601, multiple: true, hideTotals: false))
    }

    /// 締め切る前に選択肢の票数がnullなら、票数を隠す投票として送り直す。
    @Test func hiddenTotalsAreInferredFromNullVotes() {
        let resubmission = PollResubmission(poll(expiresIn: 3600, votes: nil), now: Self.now)

        #expect(resubmission?.hideTotals == true)
    }

    /// 投票を送り直せない投稿は、編集の下書きを作らない。投票なしで送ると、サーバーが投票を消すため。
    @Test func editDraftIsNilWhenPollCannotBeResent() {
        #expect(StatusDraft.edit(of: status(poll: poll(expiresIn: 299)), source: StatusSource(id: "10", text: "", spoilerText: ""), now: Self.now) == nil)
    }

    @Test func bodyIsNilWhileAttachmentIsUploading() throws {
        var draft = try #require(StatusDraft.edit(of: status(), source: StatusSource(id: "10", text: "本文", spoilerText: ""), now: Self.now))
        draft.attachments.append(DraftAttachment(state: .uploading))

        #expect(draft.editBody(poll: nil, now: Self.now) == nil)
    }

    // MARK: - 編集できる投稿

    @Test func authorshipLooksAtOriginalOfBoost() {
        let boost = status(accountID: "2", reblog: status(accountID: "1"))

        #expect(boost.isAuthored(by: "1"))
        #expect(!boost.isAuthored(by: "2"))
    }

    /// 投票の締め切りまで5分を切った投稿と、締め切った投稿は編集できない。送り直すとサーバーが拒むため。
    @Test func pollCloseToDeadlineCannotBeEdited() {
        #expect(status().canBeEdited(now: Self.now))
        #expect(status(poll: poll(expiresIn: 300)).canBeEdited(now: Self.now))
        #expect(!status(poll: poll(expiresIn: 299)).canBeEdited(now: Self.now))
        #expect(!status(poll: poll(expiresIn: 3600, expired: true)).canBeEdited(now: Self.now))
        #expect(!status(poll: poll(expiresIn: nil)).canBeEdited(now: Self.now))
        // 理由は、締め切りが近いのか、もう締め切ったのかで分ける。何日も前に締め切った投票に「5分を切った」と出さない。
        #expect(status().editObstacle(now: Self.now) == nil)
        #expect(status(poll: poll(expiresIn: 299)).editObstacle(now: Self.now) == .pollTooClose)
        #expect(status(poll: poll(expiresIn: 3600, expired: true)).editObstacle(now: Self.now) == .pollClosed)
        #expect(status(poll: poll(expiresIn: -3600)).editObstacle(now: Self.now) == .pollClosed)
        #expect(Status.EditObstacle.pollClosed.menuReason == "投票を締め切った投稿は編集できません")
        #expect(RefusalText.cannotEdit(.pollClosed).message == "投票を締め切ったため、この投稿は編集できません。")
    }
}

@Suite(.requestPurpose(.action))
struct StatusEditClientTests {
    private func makeClient(_ transport: StubTransport) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport
        )
    }

    private static let editedStatus = #"{"id":"113000000000000001","created_at":"2026-10-13T03:21:45.123Z","edited_at":"2026-10-13T04:00:00.000Z","spoiler_text":"","url":null,"content":"<p>直した</p>","visibility":"public","in_reply_to_id":null,"account":{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@alice","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]},"mentions":[],"tags":[],"emojis":[],"media_attachments":[],"sensitive":false}"#

    @Test func readsSource() async throws {
        let transport = StubTransport([.json(#"{"id":"113000000000000001","text":"@bob こんにちは","spoiler_text":""}"#, statusCode: 200)])

        let source = try await makeClient(transport).statusSource("113000000000000001")

        #expect(source == StatusSource(id: "113000000000000001", text: "@bob こんにちは", spoilerText: ""))
        #expect(await transport.requests.first?.url?.path() == "/api/v1/statuses/113000000000000001/source")
    }

    @Test func editPutsJSONAndDecodesEditedStatus() async throws {
        let transport = StubTransport([.json(Self.editedStatus, statusCode: 200)])
        let draft = StatusDraft(text: "直した + 足した", editing: StatusEditTarget(statusID: "113000000000000001", poll: nil))

        let edited = try await makeClient(transport).editStatus(try #require(draft.editing), to: draft)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/api/v1/statuses/113000000000000001")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try MastodonClientTests.jsonBody(of: request) == #"{"sensitive":false,"spoiler_text":"","status":"直した + 足した"}"#)
        #expect(edited.editedAt != nil)
    }

    /// 添付の代替テキストが`description`の、編集したあとの投稿。
    private static func edited(description: String) -> StubTransport.Response {
        .json(editedStatus.replacingOccurrences(of: #""media_attachments":[]"#, with: #""media_attachments":[{"id":"100","type":"image","url":"https://example.social/100.png","preview_url":null,"description":"\#(description)"}]"#), statusCode: 200)
    }

    /// 投稿に付いた添付の代替テキストを「猫」から「三毛猫」に変える編集。
    private static func descriptionEdit() -> StatusDraft {
        let target = StatusEditTarget(statusID: "113000000000000001", poll: nil)
        var draft = StatusDraft(text: "直した", editing: target)
        let media = MediaAttachment(id: "100", type: .image, url: URL(string: "https://example.social/100.png"), previewUrl: nil, description: "猫")
        draft.attachments = [DraftAttachment(state: .uploaded(media), description: "三毛猫", isAttachedToStatus: true)]
        return draft
    }

    private func sentRequests(_ transport: StubTransport) async -> [String] {
        await transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
    }

    /// Mastodonは編集の`media_attributes`で代替テキストを変えるので、編集だけを送る。
    @Test func editChangesDescriptionWithMediaAttributes() async throws {
        let transport = StubTransport([Self.edited(description: "三毛猫")])
        let draft = Self.descriptionEdit()

        let edited = try await makeClient(transport).editStatus(try #require(draft.editing), to: draft)

        #expect(edited.mediaAttachments.map(\.description) == ["三毛猫"])
        #expect(await sentRequests(transport) == ["PUT /api/v1/statuses/113000000000000001"])
    }

    /// `media_attributes`を読まないサーバー（Pleroma、Akkoma、Sharkey、Catodon）には、`PUT /api/v1/media/:id`で代替テキストを送り、
    /// 編集をもう一度送る。Pleroma、Akkomaは編集し直すまで投稿に出ず、Sharkey、Catodonは`PUT`ではほかのサーバーに送らないため。
    @Test func editSendsDescriptionByMediaUpdateAndResendsWhenIgnored() async throws {
        let media = #"{"id":"100","type":"image","url":"https://example.social/100.png","preview_url":null,"description":"三毛猫"}"#
        let transport = StubTransport([Self.edited(description: "猫"), .json(media, statusCode: 200), Self.edited(description: "三毛猫")])
        let draft = Self.descriptionEdit()

        let edited = try await makeClient(transport).editStatus(try #require(draft.editing), to: draft)

        #expect(edited.mediaAttachments.map(\.description) == ["三毛猫"])
        #expect(await sentRequests(transport) == [
            "PUT /api/v1/statuses/113000000000000001", "PUT /api/v1/media/100", "PUT /api/v1/statuses/113000000000000001",
        ])
        #expect(try MastodonClientTests.jsonBody(of: try #require(await transport.requests.last)) == MastodonClientTests.jsonBody(of: try #require(await transport.requests.first)))
    }

    /// 代替テキストを消したとき、返った投稿の空の代替テキストが`null`でも（Mastodon）、消えたものとして手当てを始めない。
    @Test func editTreatsNullDescriptionAsCleared() async throws {
        let cleared = StubTransport.Response.json(Self.editedStatus.replacingOccurrences(of: #""media_attachments":[]"#, with: #""media_attachments":[{"id":"100","type":"image","url":"https://example.social/100.png","preview_url":null,"description":null}]"#), statusCode: 200)
        let transport = StubTransport([cleared])
        var draft = Self.descriptionEdit()
        draft.attachments[0].description = ""

        _ = try await makeClient(transport).editStatus(try #require(draft.editing), to: draft)

        #expect(await sentRequests(transport) == ["PUT /api/v1/statuses/113000000000000001"])
    }

    /// ふつうの削除では、web UIと同じく添付もすぐ消す。削除して書き直すときは、新しい投稿に付け直すので残す。
    @Test func deleteSendsDelete() async throws {
        let transport = StubTransport([.json(Self.editedStatus, statusCode: 200), .json(Self.editedStatus, statusCode: 200)])
        let client = try makeClient(transport)

        try await client.deleteStatus("113000000000000001", deleteMedia: true)
        try await client.deleteStatus("113000000000000001", deleteMedia: false)

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["DELETE", "DELETE"])
        #expect(requests.map { $0.url?.path() } == Array(repeating: "/api/v1/statuses/113000000000000001", count: 2))
        #expect(requests.map { $0.url?.query() } == ["delete_media=true", nil])
    }
}
