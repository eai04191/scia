import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// 下書きを送るAPIの振り分けと、送った結果の知らせ先、送るときに受けた401の扱い。
@MainActor
struct DraftSubmissionTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated private static let scheduledJSON = #"{"id":"70","scheduled_at":"2027-01-01T00:00:00.000Z","params":{"text":"予約"},"media_attachments":[]}"#

    nonisolated private static func statusBody(_ id: Int) throws -> Data {
        // 1件の投稿の応答は、配列の応答の中身と同じ形。
        let array = try JSONSerialization.jsonObject(with: try TimelineModelFixtures.body([id])) as? [Any]
        return try JSONSerialization.data(withJSONObject: try #require(array?.first))
    }

    /// 投稿、予約、編集の応答を返し、どのAPIに送ったかを残すサーバー。
    nonisolated private static func server() -> RoutedTransport {
        RoutedTransport { request in
            switch (request.httpMethod, request.url?.path()) {
            case ("POST", "/api/v1/statuses"):
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                return body.contains("scheduled_at=") ? (200, Data(scheduledJSON.utf8)) : (200, try statusBody(5))
            case ("PUT", "/api/v1/statuses/4"):
                return (200, try statusBody(4))
            default:
                return (404, Data())
            }
        }
    }

    /// 投稿ボタンを押したときと同じく、使う人の操作として送る。
    private func asAction<T>(_ body: () async throws -> T) async rethrows -> T {
        try await RequestPurpose.$current.withValue(.action) { try await body() }
    }

    private func makeSession(_ transport: RoutedTransport) -> AccountSession {
        AccountSession(credential: TimelineModelFixtures.credential(), transport: transport, connector: StubWebSocketConnector(messages: []), tuning: TuningStore(defaults: nil), clock: TestClock(), now: { Self.now })
    }

    private func makeModel(submit: @escaping (StatusDraft) async throws -> SubmittedDraft) -> ComposeModel {
        let model = ComposeModel(tasks: TaskScope(), myAccountID: "1", backgroundTime: { _ in {} }, submit: submit)
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil)
        return model
    }

    /// 予約の日時も編集の対象もなければ、すぐ投稿し、サーバーが返した投稿を返す。
    @Test func draftWithoutScheduleOrEditIsPosted() async throws {
        let transport = Self.server()
        let client = MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport)

        let submitted = try await asAction { try await client.submit(StatusDraft(text: "こんにちは")) }

        guard case .posted(let status) = submitted else { Issue.record("投稿として送りませんでした: \(submitted)"); return }
        #expect(status.id == "5")
        #expect(transport.requests(to: "/api/v1/statuses").count == 1)
    }

    /// 予約の日時があれば、その日時で予約し、サーバーが返した予約を返す。
    @Test func draftWithScheduleIsScheduled() async throws {
        let transport = Self.server()
        let client = MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport)

        let submitted = try await asAction { try await client.submit(StatusDraft(text: "予約", scheduledAt: Self.now.addingTimeInterval(3600))) }

        guard case .scheduled(let scheduled) = submitted else { Issue.record("予約として送りませんでした: \(submitted)"); return }
        #expect(scheduled.id == "70")
        let body = String(decoding: try #require(transport.requests(to: "/api/v1/statuses").first?.httpBody), as: UTF8.self)
        #expect(body.contains("scheduled_at="))
    }

    /// 編集の対象があれば、予約の日時があっても編集し、サーバーが返した編集後の投稿を返す。Mastodonは編集の予約を受け付けないため。
    @Test func draftWithEditIsEditedEvenIfScheduled() async throws {
        let transport = Self.server()
        let client = MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport)
        var draft = StatusDraft(text: "直した", editing: StatusEditTarget(statusID: "4", poll: nil))
        draft.scheduledAt = Self.now.addingTimeInterval(3600)

        let submitted = try await asAction { try await client.submit(draft) }

        guard case .edited(let status) = submitted else { Issue.record("編集として送りませんでした: \(submitted)"); return }
        #expect(status.id == "4")
        #expect(transport.requests(to: "/api/v1/statuses").isEmpty)
    }

    /// 投票の付いた投稿の編集は、残りの時間をクライアントの今の日付から数える。テストで決まった日付を渡せるようにするため。
    @Test func editingPollCountsRemainingTimeFromClientClock() async throws {
        let transport = Self.server()
        let client = MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport, now: { Self.now })
        let poll = Poll(id: "50", expiresAt: Self.now.addingTimeInterval(3600.4), expired: false, multiple: false, votesCount: 0, options: [Poll.Option(title: "はい", votesCount: 0), Poll.Option(title: "いいえ", votesCount: 0)])
        let status = Status(id: "4", createdAt: Self.now, account: Account(id: "1", username: "me", acct: "me", displayName: "Me", avatar: URL(string: "https://example.social/a.png")), content: "", spoilerText: "", url: nil, visibility: .public, poll: poll)
        let draft = try #require(StatusDraft.edit(of: status, source: StatusSource(id: "4", text: "どっち？", spoilerText: ""), now: Self.now))

        _ = try await asAction { try await client.submit(draft) }

        let body = String(decoding: try #require(transport.requests(to: "/api/v1/statuses/4").first?.httpBody), as: UTF8.self)
        #expect(body.contains("poll%5Bexpires_in%5D=3601"), "\(body)")
    }

    /// 今のアカウントで送れたら、下書きを空に戻す前に、送った結果を`onSubmitted`へ渡す。
    @Test func homeSubmissionReachesOnSubmittedBeforeReset() async throws {
        let client = MastodonClient(credential: TimelineModelFixtures.credential(), transport: Self.server())
        let model = makeModel(submit: client.submit)
        var textWhenSubmitted: String?
        var postedID: Status.ID?
        model.onSubmitted = { submitted in
            textWhenSubmitted = model.text
            if case .posted(let status) = submitted { postedID = status.id }
        }
        model.text = "こんにちは"

        await asAction { await model.submit() }

        #expect(postedID == "5")
        #expect(textWhenSubmitted == "こんにちは")
        #expect(model.text.isEmpty)
    }

    /// ほかのアカウントで送ったときは、そのアカウントの`onSubmitted`だけに渡し、今のアカウントの`onSubmitted`には渡さない。IDがサーバーごとに違うため。
    @Test func otherAccountSubmissionDoesNotReachHomeLists() async throws {
        let model = makeModel { _ in
            Issue.record("今のアカウントで送りました")
            return .stub(for: StatusDraft())
        }
        var homeSubmitted = 0
        model.onSubmitted = { _ in homeSubmitted += 1 }
        var otherSubmitted: [SubmittedDraft] = []
        let client = MastodonClient(credential: TimelineModelFixtures.credential(), transport: Self.server(), isOtherAccount: true)
        let other = ComposeAccount<Never>(id: "other", myAccountID: "50", media: .unavailable, onSubmitted: { otherSubmitted.append($0) }, submit: client.submit)
        #expect(model.switchAccount(to: other))
        model.apply(configuration: nil, defaultVisibility: .public, defaultSensitive: nil, accountID: "other")
        model.text = "別のアカウントで"

        await asAction { await model.submit() }

        #expect(homeSubmitted == 0)
        #expect(otherSubmitted.count == 1)
    }

    /// セッションのクライアントで送って401を受けたら、投稿欄に理由を出し、アプリが拾わなくてもセッションがトークンを無効とする。
    @Test func unauthorizedSubmissionInvalidatesSession() async throws {
        let session = makeSession(RoutedTransport { _ in (401, Data(#"{"error":"The access token is invalid"}"#.utf8)) })
        defer { session.close() }
        var invalidated = 0
        session.onCredentialsInvalid = { invalidated += 1 }
        let model = makeModel(submit: session.client.submit)
        model.text = "こんにちは"

        await asAction { await model.submit() }

        #expect(invalidated == 1)
        #expect(session.authorization.state == .invalid)
        #expect(model.postError != nil)
        #expect(model.text == "こんにちは")
    }
}
