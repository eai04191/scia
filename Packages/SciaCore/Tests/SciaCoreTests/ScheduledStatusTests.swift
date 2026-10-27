import Foundation
import Testing
@testable import SciaCore

struct ScheduledStatusTests {
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

    private static func formItems(of request: URLRequest) throws -> [URLQueryItem] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        return components.queryItems ?? []
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static func date(_ string: String) throws -> Date {
        try Date(string, strategy: .iso8601)
    }

    /// サーバーはフォームの値をそのまま持つので、真偽値や数が文字列で返る。数で返るIDや、nullの本文と公開範囲も読む。
    @Test func decodesParamsSentAsForm() async throws {
        let transport = StubTransport([try .fixture("scheduled_statuses")])

        let statuses = try await makeClient(transport).scheduledStatuses()

        #expect(statuses.map(\.id) == ["52", "51"])
        let poll = statuses[0]
        #expect(poll.scheduledAt == (try Self.date("2026-10-28T00:00:00Z")))
        #expect(poll.params.text == "@bob どっち？")
        #expect(poll.params.visibility == .unlisted)
        #expect(poll.params.sensitive == false)
        #expect(poll.params.inReplyToID == "113000000000000000")
        #expect(poll.params.quotedStatusID == nil)
        #expect(poll.params.poll == PollDraft(options: ["朝", "夜"], multiple: true, hidesTotals: false, expiresIn: 86_400))
        let media = statuses[1]
        #expect(media.params.text == "")
        #expect(media.params.spoilerText == "ねこ")
        #expect(media.params.sensitive)
        #expect(media.params.visibility == nil)
        #expect(media.params.quotedStatusID == "113000000000000009")
        #expect(media.params.poll == nil)
        #expect(media.mediaAttachments.map(\.id) == ["113000000000000100"])
    }

    /// 続きを`Link`ヘッダーの`max_id`で、最後まで読む。
    @Test func readsAllPagesThroughLinkHeader() async throws {
        let first = #"[{"id":"60","scheduled_at":"2026-10-29T00:00:00.000Z","params":{"text":"後"},"media_attachments":[]}]"#
        let second = #"[{"id":"59","scheduled_at":"2026-10-28T00:00:00.000Z","params":{"text":"先"},"media_attachments":[]}]"#
        let transport = StubTransport([
            .json(first, statusCode: 200, headers: ["Link": #"<https://example.social/api/v1/scheduled_statuses?max_id=60>; rel="next""#]),
            .json(second, statusCode: 200),
        ])

        let statuses = try await makeClient(transport).scheduledStatuses()

        #expect(statuses.map(\.id) == ["60", "59"])
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path() } == ["/api/v1/scheduled_statuses", "/api/v1/scheduled_statuses"])
        #expect(requests[0].url?.query()?.contains("limit=40") == true)
        #expect(requests[1].url?.query()?.contains("max_id=60") == true)
    }

    /// 予約は投稿と同じフォームに`scheduled_at`を足し、同じ`Idempotency-Key`を付けて送る。
    @Test func scheduleSendsPostFormWithDate() async throws {
        let response = #"{"id":"70","scheduled_at":"2026-10-28T00:00:00.000Z","params":{"text":"おはよう","visibility":"public"},"media_attachments":[]}"#
        let transport = StubTransport([.json(response, statusCode: 200)])
        let draft = StatusDraft(text: "おはよう", visibility: .public, idempotencyKey: "key-1")

        let scheduled = try await makeClient(transport).scheduleStatus(draft, at: try Self.date("2026-10-28T00:00:00Z"))

        #expect(scheduled.id == "70")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path() == "/api/v1/statuses")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "key-1")
        #expect(try Self.formItems(of: request) == [
            URLQueryItem(name: "status", value: "おはよう"),
            URLQueryItem(name: "visibility", value: "public"),
            URLQueryItem(name: "sensitive", value: "false"),
            URLQueryItem(name: "scheduled_at", value: "2026-10-28T00:00:00Z"),
        ])
    }

    @Test func rescheduleAndCancelUseTheirPaths() async throws {
        let response = #"{"id":"70","scheduled_at":"2026-10-29T03:00:00.000Z","params":{"text":"おはよう"},"media_attachments":[]}"#
        let transport = StubTransport([.json(response, statusCode: 200), .json("{}", statusCode: 200)])
        let client = try makeClient(transport)

        let moved = try await client.rescheduleStatus("70", to: try Self.date("2026-10-29T03:00:00Z"))
        try await client.cancelScheduledStatus("70")

        #expect(moved.scheduledAt == (try Self.date("2026-10-29T03:00:00Z")))
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "DELETE"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/scheduled_statuses/70", "/api/v1/scheduled_statuses/70"])
        #expect(try Self.formItems(of: requests[0]) == [URLQueryItem(name: "scheduled_at", value: "2026-10-29T03:00:00Z")])
    }

    /// サーバーは今から5分以内を断り、過去の日時はすぐ投稿するので、どちらも予約できないものとする。
    @Test func acceptsOnlyDatesBeyondMinimumLeadTime() throws {
        let now = try Self.date("2026-10-27T10:00:00Z")

        #expect(!ScheduledPosting.accepts(now.addingTimeInterval(-60), now: now))
        #expect(!ScheduledPosting.accepts(now.addingTimeInterval(5 * 60), now: now))
        #expect(ScheduledPosting.accepts(now.addingTimeInterval(5 * 60 + 1), now: now))
    }

    /// 選べる最も早い日時は、5分より後の、分の区切り。
    @Test func earliestDateIsNextMinuteBeyondLeadTime() throws {
        #expect(ScheduledPosting.earliestDate(now: try Self.date("2026-10-27T10:00:00Z"), calendar: Self.utc) == (try Self.date("2026-10-27T10:06:00Z")))
        #expect(ScheduledPosting.earliestDate(now: try Self.date("2026-10-27T10:00:30Z"), calendar: Self.utc) == (try Self.date("2026-10-27T10:06:00Z")))
        #expect(ScheduledPosting.earliestDate(now: try Self.date("2026-10-27T10:00:59Z"), calendar: Self.utc) == (try Self.date("2026-10-27T10:06:00Z")))
    }

    /// 足した直後の日時は、1時間より先の、いちばん近い正時。
    @Test func defaultDateIsNextHourBeyondOneHour() throws {
        #expect(ScheduledPosting.defaultDate(now: try Self.date("2026-10-27T10:20:00Z"), calendar: Self.utc) == (try Self.date("2026-10-27T12:00:00Z")))
        #expect(ScheduledPosting.defaultDate(now: try Self.date("2026-10-27T10:00:00Z"), calendar: Self.utc) == (try Self.date("2026-10-27T11:00:00Z")))
        #expect(ScheduledPosting.defaultDate(now: try Self.date("2026-10-27T23:30:00Z"), calendar: Self.utc) == (try Self.date("2026-10-28T01:00:00Z")))
    }

    /// 書き直す下書きには、予約したときの内容と日時を戻す。公開範囲を送っていない予約では、既定の公開範囲にする。
    @Test func rewriteRestoresScheduledContent() async throws {
        let transport = StubTransport([try .fixture("scheduled_statuses")])
        let statuses = try await makeClient(transport).scheduledStatuses()

        let poll = StatusDraft.rewrite(of: statuses[0])
        let media = StatusDraft.rewrite(of: statuses[1], defaultVisibility: .private)

        #expect(poll.text == "@bob どっち？")
        #expect(poll.visibility == .unlisted)
        #expect(poll.inReplyToID == "113000000000000000")
        #expect(poll.poll?.filledOptions == ["朝", "夜"])
        #expect(poll.scheduledAt == statuses[0].scheduledAt)
        #expect(poll.editing == nil)
        #expect(media.visibility == .private)
        #expect(media.spoilerText == "ねこ")
        #expect(media.hasSpoiler)
        #expect(media.sensitive)
        #expect(media.quotedStatusID == "113000000000000009")
        #expect(media.mediaIDs == ["113000000000000100"])
        #expect(media.attachments.first?.description == "窓辺の猫")
        #expect(media.attachments.first?.isAttachedToStatus == false)
    }

    /// 添付は、投稿するときと同じく`params.media_ids`の順に並べる。サーバーはデータベースの順で返すため。
    @Test func ordersAttachmentsByMediaIDs() throws {
        let json = #"{"id":"80","scheduled_at":"2026-10-28T00:00:00.000Z","params":{"text":"並べ替え","media_ids":["2","1"]},"media_attachments":[{"id":"1","type":"image","url":"https://example.social/1.jpg","preview_url":null},{"id":"2","type":"image","url":"https://example.social/2.jpg","preview_url":null}]}"#

        let scheduled = try MastodonDecoder.make().decode(ScheduledStatus.self, from: Data(json.utf8))

        #expect(scheduled.params.mediaIDs == ["2", "1"])
        #expect(scheduled.mediaAttachments.map(\.id) == ["2", "1"])
        #expect(StatusDraft.rewrite(of: scheduled).mediaIDs == ["2", "1"])
    }
}
