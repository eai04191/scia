import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// 使えないと分かった機能は、そのセッションの間だけ止める。次のセッションではもう一度試す。
@Suite(.requestPurpose(.action))
struct FeatureAvailabilityTests {
    private func makeClient(_ transport: StubTransport, features: FeatureAvailability) throws -> MastodonClient {
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
            features: features,
            retry: RetryPolicy(maxRetries: 0, initialDelay: .zero)
        )
    }

    @Test(arguments: [404, 405, 410, 501])
    func unsupportedMarkersAreStoppedForSession(statusCode: Int) async throws {
        let features = FeatureAvailability()
        let transport = StubTransport([.json("<html>Not Found</html>", statusCode: statusCode)])
        let client = try makeClient(transport, features: features)

        // 止めると決めた呼び出しも、止めた機能として失敗させる。呼び出し側が、ほかの失敗と分けて扱えるようにする。
        await #expect(throws: FeatureUnavailable.self) { try await client.marker(for: .home) }
        await #expect(throws: FeatureUnavailable.self) { try await client.marker(for: .notifications) }
        await #expect(throws: FeatureUnavailable.self) { try await client.saveMarker(for: .home, lastReadID: "1") }

        #expect(await transport.requests.count == 1)
        #expect(await features.disabled.map(\.feature) == [.markers])
        #expect(await features.disabled.first?.statusCode == statusCode)
    }

    /// 保存で使えないと分かっても、読み込みも止める。同じ機能のため。
    @Test func unsupportedMarkerSaveStopsLoadingToo() async throws {
        let features = FeatureAvailability()
        let transport = StubTransport([.json("<html>Not Found</html>", statusCode: 404)])
        let client = try makeClient(transport, features: features)

        await #expect(throws: FeatureUnavailable.self) { try await client.saveMarker(for: .home, lastReadID: "1") }

        await #expect(throws: FeatureUnavailable.self) { try await client.marker(for: .home) }
        #expect(await transport.requests.count == 1)
    }

    /// 一時的な失敗では止めない。
    @Test(arguments: [500, 502, 503, 409, 422])
    func otherFailuresDoNotStopFeature(statusCode: Int) async throws {
        let features = FeatureAvailability()
        let transport = StubTransport([
            .json(#"{"error":"x"}"#, statusCode: statusCode),
            .json(#"{"home":{"last_read_id":"1","version":1,"updated_at":"2026-10-13T03:21:45.123Z"}}"#, statusCode: 200),
        ])
        let client = try makeClient(transport, features: features)

        await #expect(throws: MastodonAPIError.self) { try await client.marker(for: .home) }

        #expect(try await client.marker(for: .home) == "1")
        #expect(await features.disabled.isEmpty)
    }

    /// 投稿やタイムラインのような、なくてはならない機能は止めない。404は個々の投稿などがないことを表しうるため。
    @Test func requiredEndpointsAreNotStopped() async throws {
        let features = FeatureAvailability()
        let transport = StubTransport([
            .json(#"{"error":"Record not found"}"#, statusCode: 404),
            .json(#"{"error":"Record not found"}"#, statusCode: 404),
        ])
        let client = try makeClient(transport, features: features)

        await #expect(throws: MastodonAPIError.self) { try await client.homeTimeline(TimelineQuery(limit: 40)) }
        await #expect(throws: MastodonAPIError.self) { try await client.favourite("1") }

        #expect(await transport.requests.count == 2)
        #expect(await features.disabled.isEmpty)
    }

    @Test func unsupportedPreferencesAreStopped() async throws {
        let features = FeatureAvailability()
        let transport = StubTransport([.json("<html>Not Found</html>", statusCode: 404)])
        let client = try makeClient(transport, features: features)

        await #expect(throws: FeatureUnavailable.self) { try await client.preferences() }
        await #expect(throws: FeatureUnavailable.self) { try await client.preferences() }

        #expect(await features.disabled.map(\.feature) == [.preferences])
    }

    /// v2のinstanceがないサーバーでは、投稿欄の上限を読むたびに送らず、ストリーミングの接続先はすぐv1を使う。
    @Test func unsupportedInstanceV2FallsBackToV1WithoutRequestingAgain() async throws {
        let features = FeatureAvailability()
        let transport = StubTransport([
            .json("<html>Not Found</html>", statusCode: 404),
            .json(#"{"uri":"example.social","urls":{"streaming_api":"wss://v1.example.social"}}"#, statusCode: 200),
        ])
        let client = try makeClient(transport, features: features)

        await #expect(throws: FeatureUnavailable.self) { try await client.instanceConfiguration() }
        await #expect(throws: FeatureUnavailable.self) { try await client.instanceConfiguration() }
        #expect(try await StreamingEndpoint(client: client).url().absoluteString == "wss://v1.example.social")

        #expect(await transport.requests.map { $0.url?.path() } == ["/api/v2/instance", "/api/v1/instance"])
    }

    /// ホームと通知は既読位置を並行して読む。片方が送り直しを待っている間にもう片方が止めたら、送り直さない。
    @Test func retryStopsWhenFeatureIsDisabledWhileWaiting() async throws {
        let features = FeatureAvailability()
        let clock = TestClock()
        let transport = StubTransport([.json("<html>502</html>", statusCode: 502)])
        let client = MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport,
            features: features,
            retry: RetryPolicy(maxRetries: 2, initialDelay: .milliseconds(100)),
            clock: clock
        )

        let loading = Task { try await client.marker(for: .home) }
        // 実際の時間で待つと、止める前に待ちが明けて送り直すことがあるため、送り直しの待ちに入ったのを確かめてから止め、時計を進める。
        try await waitUntil { clock.sleeperCount == 1 }
        await features.disable(.markers, statusCode: 404)
        clock.advance(by: .milliseconds(100))

        await #expect(throws: FeatureUnavailable.self) { try await loading.value }
        #expect(await transport.requests.count == 1)
    }

    /// 次のセッションでは、もう一度試す。サーバーが更新されて使えるようになることがあるため、サーバーごとには覚えない。
    @Test func newSessionTriesAgain() async throws {
        let transport = StubTransport([
            .json("<html>Not Found</html>", statusCode: 404),
            .json(#"{"home":{"last_read_id":"1","version":1,"updated_at":"2026-10-13T03:21:45.123Z"}}"#, statusCode: 200),
        ])

        await #expect(throws: FeatureUnavailable.self) { try await makeClient(transport, features: FeatureAvailability()).marker(for: .home) }

        #expect(try await makeClient(transport, features: FeatureAvailability()).marker(for: .home) == "1")
    }

    private static let account = #"{"id":"2","username":"bob","acct":"bob@remote.example","display_name":"Bob","avatar":"https://example.social/avatars/bob.png","avatar_static":"https://example.social/avatars/bob.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://remote.example/@bob","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
    private static let ungroupedNotifications = #"[{"id":"20","type":"favourite","created_at":"2026-10-13T03:26:00.000Z","account":\#(account)},{"id":"19","type":"follow","created_at":"2026-10-13T03:20:00.000Z","account":\#(account)}]"#

    /// 通知のv2がない（Mastodon 4.2以前）サーバーでは、v1でまとめずに読み、以後はv2を送らない。
    @Test func unsupportedGroupedNotificationsFallBackToV1() async throws {
        let features = FeatureAvailability()
        let transport = StubTransport([
            .json("<html>Not Found</html>", statusCode: 404),
            .json(Self.ungroupedNotifications, statusCode: 200),
            .json(Self.ungroupedNotifications, statusCode: 200),
        ])
        let client = try makeClient(transport, features: features)

        let page = try await client.notifications(TimelineQuery(maxID: "30", limit: 40))
        _ = try await client.notifications(TimelineQuery(limit: 40))

        #expect(page.notifications.map(\.id) == ["20", "19"])
        // まとめる種類の通知も、1件で1行にする。
        #expect(page.notifications.map(\.groupKey) == ["ungrouped-20", "ungrouped-19"])
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path() } == ["/api/v2/notifications", "/api/v1/notifications", "/api/v1/notifications"])
        let query = try #require(requests[1].url?.query())
        #expect(query.contains("max_id=30"))
        #expect(!query.contains("grouped_types"))
        #expect(await features.disabled.map(\.feature) == [.groupedNotifications])
    }

    /// v2で読めているサーバーでは、v2のまとまりのキーで消す。
    @Test func dismissUsesV2WhileGroupedNotificationsAreAvailable() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200)])
        let client = try makeClient(transport, features: FeatureAvailability())

        try await client.dismissNotificationGroup("ungrouped-20")

        #expect(await transport.requests.map { $0.url?.path() } == ["/api/v2/notifications/ungrouped-20/dismiss"])
    }

    /// v2がないと分かったあとは、通知をv1で1件ずつ消す。
    @Test func dismissUsesV1AfterGroupedNotificationsAreUnsupported() async throws {
        let features = FeatureAvailability()
        let transport = StubTransport([
            .json("<html>Not Found</html>", statusCode: 404),
            .json(Self.ungroupedNotifications, statusCode: 200),
            .json("{}", statusCode: 200),
        ])
        let client = try makeClient(transport, features: features)
        _ = try await client.notifications(TimelineQuery(limit: 40))

        try await client.dismissNotificationGroup("ungrouped-20")

        let request = try #require(await transport.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v1/notifications/20/dismiss")
    }

    /// 通知のフィルタリングのAPIがない（Mastodon 4.2以前）サーバーでは、設定、保留中の通知、取り込みの問い合わせを止める。
    @Test func unsupportedNotificationFilterIsStopped() async throws {
        let features = FeatureAvailability()
        let transport = StubTransport([.json("<html>Not Found</html>", statusCode: 404)])
        let client = try makeClient(transport, features: features)

        await #expect(throws: FeatureUnavailable.self) { try await client.notificationPolicy() }
        await #expect(throws: FeatureUnavailable.self) { try await client.notificationRequests(maxID: nil, limit: 40) }
        await #expect(throws: FeatureUnavailable.self) { try await client.notificationRequestsMerged() }
        await #expect(throws: FeatureUnavailable.self) { try await client.updateNotificationPolicy([.notFollowing: .filter]) }

        #expect(await transport.requests.count == 1)
        #expect(await features.disabled.map(\.feature) == [.notificationFilter])
    }
}
