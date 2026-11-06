import Foundation
import Testing
@testable import SciaCore

@Suite(.requestPurpose(.action))
struct NotificationPolicyTests {
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

    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func decodesPolicyItemsAndSummary() throws {
        let policy = try MastodonDecoder.make().decode(NotificationPolicy.self, from: Data(fixture("notification_policy").utf8))

        #expect(policy[.notFollowing] == .accept)
        #expect(policy[.notFollowers] == .filter)
        #expect(policy[.newAccounts] == .drop)
        #expect(policy[.privateMentions] == .filter)
        #expect(policy[.limitedAccounts] == .filter)
        #expect(policy.pendingRequestsCount == 3)
        #expect(policy.pendingNotificationsCount == 7)
    }

    /// 知らない値は、送らない値として持つ。項目のないサーバーでは、その項目を持たない。
    @Test func keepsUnknownValuesAndSkipsMissingItems() throws {
        let json = #"{"for_not_following":"quarantine","for_not_followers":"accept","summary":{"pending_requests_count":0,"pending_notifications_count":0}}"#

        let policy = try MastodonDecoder.make().decode(NotificationPolicy.self, from: Data(json.utf8))

        #expect(policy[.notFollowing] == .unknown("quarantine"))
        #expect(policy[.notFollowing]?.rawValue == nil)
        #expect(policy[.notFollowers] == .accept)
        #expect(policy[.newAccounts] == nil)
    }

    @Test func clampsPendingCounts() throws {
        let json = #"{"for_not_following":"accept","summary":{"pending_requests_count":-5,"pending_notifications_count":99999999999}}"#

        let policy = try MastodonDecoder.make().decode(NotificationPolicy.self, from: Data(json.utf8))

        #expect(policy.pendingRequestsCount == ServerCount.clamped(-5))
        #expect(policy.pendingNotificationsCount == ServerCount.clamped(99_999_999_999))
    }

    /// 件数は文字列で届く。読めない件数のまとまりは、結果から外して読めないものとして数える。
    @Test func decodesRequestsWithStringCounts() async throws {
        let transport = StubTransport([
            .json(try fixture("notification_requests"), statusCode: 200, headers: ["Link": #"<https://example.social/api/v1/notifications/requests?max_id=112456967201894200>; rel="next""#]),
        ])

        let page = try await makeClient(transport).notificationRequests(maxID: nil, limit: 40)

        #expect(page.requests.map(\.id) == ["112456967201894256", "112456967201894200"])
        #expect(page.requests.map(\.notificationsCount) == [5, 1])
        #expect(page.requests.first?.lastStatus?.id == "113000000000000001")
        #expect(page.requests.last?.lastStatus == nil)
        #expect(page.nextMaxID == "112456967201894200")
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/notifications/requests")
        #expect(Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []) == [URLQueryItem(name: "limit", value: "40")])
    }

    @Test func requestWithUnreadableCountIsDropped() throws {
        let account = try fixture("account")
        let json = #"[{"id":"1","created_at":"2026-10-17T14:45:41.171Z","updated_at":"2026-10-17T14:45:41.171Z","notifications_count":"many","account":"# + account + "}]"

        let list = try MastodonDecoder.make().decode(ElementList<NotificationRequest>.self, from: Data(json.utf8))

        #expect(list.elements.isEmpty)
    }

    /// 変えた項目だけを、知らない値を除いて送る。
    @Test func updateSendsOnlyChangedKnownItems() async throws {
        let transport = StubTransport([.json(try fixture("notification_policy"), statusCode: 200)])

        _ = try await makeClient(transport).updateNotificationPolicy([.newAccounts: .filter, .notFollowing: .unknown("quarantine")])

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/api/v2/notifications/policy")
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == "for_new_accounts=filter")
    }

    @Test func answersRequestsOnTheirPaths() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200), .json("{}", statusCode: 200)])
        let client = try makeClient(transport)

        try await client.answerNotificationRequest("7", .accept)
        try await client.answerNotificationRequest("8", .dismiss)

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/notifications/requests/7/accept", "/api/v1/notifications/requests/8/dismiss"])
    }

    @Test func readsMergedState() async throws {
        let transport = StubTransport([.json(#"{"merged":true}"#, statusCode: 200)])

        #expect(try await makeClient(transport).notificationRequestsMerged())
        #expect(await transport.requests.first?.url?.path() == "/api/v1/notifications/requests/merged")
    }

    /// その人からの通知は、`account_id`を読むv1で読み、まとめずに1件ずつにする。v2はサーバーが`account_id`を読まないため。
    @Test func notificationsFromAccountUseV1AndStayUngrouped() async throws {
        let account = try fixture("account")
        let json = #"[{"id":"20","type":"favourite","created_at":"2026-10-13T03:26:00.000Z","group_key":"favourite-1-2","account":"# + account + #"}]"#
        let transport = StubTransport([.json(json, statusCode: 200)])

        let page = try await makeClient(transport).notifications(TimelineQuery(limit: 40), from: "2")

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/notifications")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "account_id", value: "2")))
        #expect(page.notifications.map(\.groupKey) == ["ungrouped-20"])
    }

    @Test func decodesNotificationsMergedEvent() throws {
        #expect(try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"notifications_merged","payload":"1"}"#).event == .notificationsMerged)
    }
}
