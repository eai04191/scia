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
        reblog: Status? = nil
    ) -> Status {
        Status(
            id: "10",
            createdAt: Self.now,
            account: account(accountID),
            content: "<p>本文</p>",
            spoilerText: spoilerText,
            url: nil,
            mediaAttachments: media,
            sensitive: sensitive,
            visibility: .private,
            inReplyToId: "9",
            poll: poll,
            reblog: reblog
        )
    }

    private func form(_ draft: StatusDraft) throws -> [URLQueryItem] {
        let editing = try #require(draft.editing)
        return try #require(draft.editForm(poll: editing.poll, now: Self.now))
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

    // MARK: - 送るフォーム

    /// 送ったが届いたか分からない代替テキストは、元と同じ値に戻しても送る。応答だけを失い、サーバーが書き換えた値のままのことがあるため。
    @Test func unconfirmedDescriptionIsSentEvenWhenRestored() throws {
        var draft = try #require(StatusDraft.edit(of: status(media: [media("100", description: "猫")]), source: StatusSource(id: "10", text: "", spoilerText: ""), now: Self.now))
        draft.attachments[0].hasUnconfirmedDescription = true

        #expect(try form(draft).filter { $0.name.hasPrefix("media_attributes") } == [
            URLQueryItem(name: "media_attributes[][id]", value: "100"),
            URLQueryItem(name: "media_attributes[][description]", value: "猫"),
        ])
    }

    /// 変えていない添付、注意書き、閲覧注意も毎回送る。送らなければサーバーが消すため。公開範囲と返信先は送らない。
    @Test func formSendsEveryEditableField() throws {
        let draft = try #require(StatusDraft.edit(of: status(media: [media("100", description: "猫")], sensitive: true), source: StatusSource(id: "10", text: "本文", spoilerText: ""), now: Self.now))

        #expect(try form(draft) == [
            URLQueryItem(name: "status", value: "本文"),
            URLQueryItem(name: "spoiler_text", value: ""),
            URLQueryItem(name: "sensitive", value: "true"),
            URLQueryItem(name: "media_ids[]", value: "100"),
        ])
    }

    /// 書き換えた代替テキストは、要素ごとにidを先に置いて送る。新しく足した添付は、アップロードの流れで送り済みなので含めない。
    @Test func formSendsChangedDescriptionsOfAttachedMedia() throws {
        var draft = try #require(StatusDraft.edit(of: status(media: [media("100", description: "猫"), media("101")]), source: StatusSource(id: "10", text: "", spoilerText: ""), now: Self.now))
        draft.attachments[0].description = "三毛猫"
        draft.attachments[1].description = "犬"
        draft.attachments.append(DraftAttachment(state: .uploaded(media("102", description: "鳥")), description: "鳥"))

        let attributes = try form(draft).filter { $0.name.hasPrefix("media_attributes") }

        #expect(attributes == [
            URLQueryItem(name: "media_attributes[][id]", value: "100"),
            URLQueryItem(name: "media_attributes[][description]", value: "三毛猫"),
            URLQueryItem(name: "media_attributes[][id]", value: "101"),
            URLQueryItem(name: "media_attributes[][description]", value: "犬"),
        ])
        #expect(try form(draft).filter { $0.name == "media_ids[]" }.map(\.value) == ["100", "101", "102"])
    }

    /// 添付を全部外したら`media_ids[]`を送らない。空の値は、サーバーがIDの0として探して拒むため。
    @Test func formOmitsMediaIDsWhenAllRemoved() throws {
        var draft = try #require(StatusDraft.edit(of: status(media: [media("100")]), source: StatusSource(id: "10", text: "本文", spoilerText: ""), now: Self.now))
        draft.attachments.removeAll()

        #expect(try form(draft).allSatisfy { !$0.name.hasPrefix("media") })
    }

    /// 投票は、選択肢、複数選べるか、票数を隠すかを元のまま、残りの時間で送り直す。
    @Test func formResendsPollAsIs() throws {
        let draft = try #require(StatusDraft.edit(of: status(poll: poll(expiresIn: 3600.4)), source: StatusSource(id: "10", text: "どっち？", spoilerText: ""), now: Self.now))

        #expect(try form(draft).filter { $0.name.hasPrefix("poll") } == [
            URLQueryItem(name: "poll[options][]", value: "はい"),
            URLQueryItem(name: "poll[options][]", value: "いいえ"),
            URLQueryItem(name: "poll[expires_in]", value: "3601"),
            URLQueryItem(name: "poll[multiple]", value: "true"),
            URLQueryItem(name: "poll[hide_totals]", value: "false"),
        ])
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

    @Test func formIsNilWhileAttachmentIsUploading() throws {
        var draft = try #require(StatusDraft.edit(of: status(), source: StatusSource(id: "10", text: "本文", spoilerText: ""), now: Self.now))
        draft.attachments.append(DraftAttachment(state: .uploading))

        #expect(draft.editForm(poll: nil, now: Self.now) == nil)
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
    }
}

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

    @Test func editPutsFormAndDecodesEditedStatus() async throws {
        let transport = StubTransport([.json(Self.editedStatus, statusCode: 200)])
        let draft = StatusDraft(text: "直した + 足した", editing: StatusEditTarget(statusID: "113000000000000001", poll: nil))

        let edited = try await makeClient(transport).editStatus(try #require(draft.editing), to: draft)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/api/v1/statuses/113000000000000001")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(components.queryItems?.first == URLQueryItem(name: "status", value: "直した + 足した"))
        #expect(edited.editedAt != nil)
    }

    @Test func deleteSendsDelete() async throws {
        let transport = StubTransport([.json(Self.editedStatus, statusCode: 200)])

        try await makeClient(transport).deleteStatus("113000000000000001")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path() == "/api/v1/statuses/113000000000000001")
    }
}
