import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// 開発者が試していないサーバーやプロキシが返しそうな壊れた応答を、クライアントから一覧の表示まで通して確かめる。
/// 個々の項目の読み方はLenientDecodingTests、件数を丸めるサーバーはTimelineGapTestsのFakeHomeServerで確かめている。
@MainActor
struct BrokenResponseTests {
    private func makeClient(_ transport: StubTransport, rateLimit: RateLimitGate = RateLimitGate(), requestLog: RequestLog = RequestLog(includesBody: false)) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport,
            rateLimit: rateLimit,
            retry: RetryPolicy(maxRetries: 2, initialDelay: .zero),
            requestLog: requestLog
        )
    }

    /// 項目が空や欠落の投稿は読み、読めない投稿は「表示できない」行にし、IDもないものだけを外す。
    @Test func homeTimelineFromOtherServerKeepsWhatCanBeShown() async throws {
        let client = try makeClient(StubTransport([try .fixture("home_timeline_broken")]))
        let droppedBefore = DecodingLog.droppedCount

        let page = try await client.homeTimeline(TimelineQuery(limit: 40))

        #expect(page.statuses.map(\.id) == ["113000000000000105", "113000000000000102", "113000000000000101"])
        #expect(page.unreadable.map(\.id) == ["113000000000000104"])
        #expect(page.unreadable.first?.url?.absoluteString == "https://example.social/@alice/113000000000000104")
        let fromOtherServer = try #require(page.statuses.first)
        #expect(fromOtherServer.url == nil)
        #expect(fromOtherServer.account.avatar == nil)
        #expect(fromOtherServer.mentions.isEmpty)
        #expect(page.statuses[1].mediaAttachments.count == 1, "IDのない添付ファイルだけを外します")
        // 読めない投稿、IDのない要素、IDのない添付ファイル。数はプロセス全体で数えるため、並行する他のテストでも増える。
        #expect(DecodingLog.droppedCount >= droppedBefore + 3)

        let store = TimelineStore(pageSize: 40) { _ in page }
        _ = try await store.loadInitial()
        #expect(store.entries.map(\.id) == [
            .status("113000000000000105"),
            .unreadable("113000000000000104"),
            .status("113000000000000102"),
            .status("113000000000000101"),
        ])
    }

    /// 知らない種類の通知は読み、読めない通知は「表示できない」行にする。
    @Test func notificationsFromOtherServerKeepWhatCanBeShown() async throws {
        let client = try makeClient(StubTransport([try .fixture("grouped_notifications_broken")]))

        let page = try await client.notifications(TimelineQuery(limit: 40))

        #expect(page.notifications.map(\.id) == ["34975870", "34975867"])
        #expect(page.notifications.map(\.type) == [.favourite, .other("quote_of_a_future_version")])
        #expect(page.unreadable.map(\.id) == ["34975869", "34975868"])
        #expect(page.unreadable.first?.url?.absoluteString == "https://example.social/@alice/113000000000000104", "通知の対象の投稿のURLで開けるようにします")
    }

    /// プロキシが返すHTMLのエラーページは、送り直したうえで種類ごとの文言にし、本文は見せず記録にも残さない。
    @Test func proxyErrorPageIsRetriedAndShownByKind() async throws {
        let transport = StubTransport(Array(repeating: try .fixture("error_502", withExtension: "html", statusCode: 502), count: 3))
        let log = RequestLog(includesBody: false)
        let client = try makeClient(transport, requestLog: log)

        let error = await #expect(throws: MastodonAPIError.self) { try await client.homeTimeline(TimelineQuery(limit: 40)) }

        #expect(await transport.requests.count == 3)
        let presentation = ErrorPresentation(try #require(error))
        #expect(presentation.message == "サーバーが一時的に応答できません。しばらく待ってからやり直してください。")
        #expect(presentation.code == "HTTP 502")
        #expect(log.recentFailures.map(\.logMessage) == ["GET /api/v1/timelines/home HTTP 502"])
    }

    /// Mastodonの429は、X-RateLimit-Resetの時刻まで自動の通信を止める。使う人の操作は止めない。
    @Test func mastodonRateLimitPausesAutomaticRequests() async throws {
        let clock = TestClock()
        let reset = clock.date.addingTimeInterval(300)
        let headers = [
            "X-RateLimit-Limit": "300",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": reset.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)),
        ]
        let rateLimit = RateLimitGate(now: { clock.date }, clock: clock)
        let transport = StubTransport([try .fixture("rate_limited", statusCode: 429, headers: headers), try .fixture("home_timeline")])
        let client = try makeClient(transport, rateLimit: rateLimit)

        let error = await #expect(throws: MastodonAPIError.self) { try await client.homeTimeline(TimelineQuery(limit: 40)) }

        #expect(ErrorPresentation(try #require(error)).code == "HTTP 429")
        let pausedUntil = try #require(await rateLimit.pausedUntil)
        #expect(abs(pausedUntil.timeIntervalSince(reset)) < 0.01)
        await #expect(throws: AutomaticRequestsPaused.self) {
            try await RequestOrigin.$current.withValue(.automatic) { try await client.homeTimeline(TimelineQuery(limit: 40)) }
        }
        _ = try await client.homeTimeline(TimelineQuery(limit: 40))
    }
}
