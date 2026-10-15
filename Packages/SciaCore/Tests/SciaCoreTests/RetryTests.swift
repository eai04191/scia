import Foundation
import Testing
@testable import SciaCore

/// 一時的な失敗で自動で送り直すのは、何度送っても結果が変わらないGETと、`Idempotency-Key`付きの投稿だけ。
struct RetryTests {
    private static let noWait = RetryPolicy(maxRetries: 2, initialDelay: .zero)

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
            transport: transport,
            retry: Self.noWait
        )
    }

    @Test(arguments: [502, 503, 504])
    func getRetriesTemporaryServerErrors(statusCode: Int) async throws {
        let transport = StubTransport([.json("<html>\(statusCode)</html>", statusCode: statusCode), try .fixture("home_timeline")])

        _ = try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40))

        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost])
    func getRetriesConnectionFailures(code: URLError.Code) async throws {
        let transport = StubTransport([.failure(code), try .fixture("home_timeline")])

        _ = try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40))

        #expect(await transport.requests.count == 2)
    }

    @Test func givesUpAfterMaxRetries() async throws {
        let transport = StubTransport(Array(repeating: .json("<html>502</html>", statusCode: 502), count: 3))

        let error = await #expect(throws: MastodonAPIError.self) { try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40)) }

        #expect(error?.statusCode == 502)
        #expect(await transport.requests.count == 3)
    }

    /// 結果が変わらない失敗は送り直さない。
    @Test(arguments: [400, 401, 404, 422, 500])
    func doesNotRetryOtherStatuses(statusCode: Int) async throws {
        let transport = StubTransport([.json(#"{"error":"x"}"#, statusCode: statusCode)])

        await #expect(throws: MastodonAPIError.self) { try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40)) }

        #expect(await transport.requests.count == 1)
    }

    /// 再開の時刻が分かる429や503は、送り直さずに自動の通信を止める。
    @Test func doesNotRetryWhenServerAsksToWait() async throws {
        let transport = StubTransport([.json("<html>503</html>", statusCode: 503, headers: ["Retry-After": "30"])])

        await #expect(throws: MastodonAPIError.self) { try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40)) }

        #expect(await transport.requests.count == 1)
    }

    @Test func postStatusWithIdempotencyKeyIsRetried() async throws {
        let transport = StubTransport([.failure(.networkConnectionLost), try .fixture("status")])

        _ = try await makeClient(transport).postStatus(StatusDraft(text: "こんにちは", idempotencyKey: "key-1"))

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") == "key-1" })
    }

    /// お気に入りなどは、届いていたかどうか分からないまま送り直さない。
    @Test func postWithoutIdempotencyKeyIsNotRetried() async throws {
        let transport = StubTransport([.failure(.networkConnectionLost)])

        await #expect(throws: URLError.self) { try await makeClient(transport).favourite("1") }

        #expect(await transport.requests.count == 1)
    }

    @Test func retryDelayDoubles() {
        let policy = RetryPolicy(maxRetries: 3, initialDelay: .seconds(1))
        #expect((1...3).map(policy.delay(beforeRetry:)) == [.seconds(1), .seconds(2), .seconds(4)])
    }
}
