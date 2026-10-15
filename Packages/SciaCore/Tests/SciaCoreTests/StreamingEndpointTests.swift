import Foundation
import Testing
@testable import SciaCore

struct StreamingEndpointTests {
    private func makeEndpoint(_ transport: StubTransport) throws -> StreamingEndpoint {
        StreamingEndpoint(client: MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport,
            // v2とv1の切り替えを確かめる。一時的な失敗の送り直しはRetryTestsで確かめる。
            retry: RetryPolicy(maxRetries: 0, initialDelay: .zero)
        ))
    }

    private static let v1Instance = StubTransport.Response.json(#"{"uri":"example.social","urls":{"streaming_api":"wss://v1.example.social"}}"#, statusCode: 200)

    @Test func readsV2OnceAndRemembersIt() async throws {
        let transport = StubTransport([try .fixture("instance_v2")])
        let endpoint = try makeEndpoint(transport)

        #expect(try await endpoint.url().absoluteString == "wss://streaming.example.social")
        #expect(try await endpoint.url().absoluteString == "wss://streaming.example.social")
        #expect(await transport.requests.map { $0.url?.path() } == ["/api/v2/instance"])
    }

    @Test func fallsBackToV1WhenV2IsMissing() async throws {
        let transport = StubTransport([
            .json("<html><body>Not Found</body></html>", statusCode: 404),
            Self.v1Instance,
        ])
        let endpoint = try makeEndpoint(transport)

        #expect(try await endpoint.url().absoluteString == "wss://v1.example.social")
        #expect(try await endpoint.url().absoluteString == "wss://v1.example.social")
        #expect(await transport.requests.map { $0.url?.path() } == ["/api/v2/instance", "/api/v1/instance"])
    }

    /// v2はあるが、接続先を返さないサーバー。
    @Test func fallsBackToV1WhenV2LacksStreamingURL() async throws {
        let transport = StubTransport([
            .json(#"{"configuration":{"urls":{}}}"#, statusCode: 200),
            Self.v1Instance,
        ])

        #expect(try await makeEndpoint(transport).url().absoluteString == "wss://v1.example.social")
    }

    /// 通信の失敗などで読めなかったときは覚えず、次につなぐときに調べ直す。
    @Test func retriesAfterBothFail() async throws {
        let transport = StubTransport([
            .json("<html>Bad Gateway</html>", statusCode: 502),
            .json("<html>Bad Gateway</html>", statusCode: 502),
            try .fixture("instance_v2"),
        ])
        let endpoint = try makeEndpoint(transport)

        await #expect(throws: MastodonAPIError.self) { try await endpoint.url() }
        #expect(try await endpoint.url().absoluteString == "wss://streaming.example.social")
    }

    /// 記録に残すサーバーの版。v2のinstanceがなければv1から読む。
    @Test func serverVersionFallsBackToV1() async throws {
        let transport = StubTransport([
            .json("<html>Not Found</html>", statusCode: 404),
            .json(#"{"uri":"example.social","version":"3.5.3","urls":{"streaming_api":"wss://example.social"}}"#, statusCode: 200),
        ])
        let client = MastodonClient(
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

        #expect(try await client.serverVersion() == "3.5.3")
    }

    @Test func serverVersionReadsV2() async throws {
        let transport = StubTransport([.json(#"{"version":"4.3.0+glitch","configuration":{"urls":{"streaming":"wss://example.social"}}}"#, statusCode: 200)])
        let client = MastodonClient(
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

        #expect(try await client.serverVersion() == "4.3.0+glitch")
    }

    /// トークンが無効なら、ストリーミングの接続と同じく401として呼び出し側に知らせる。
    @Test func reportsUnauthorizedFromV1() async throws {
        let transport = StubTransport([
            .json(#"{"error":"The access token is invalid"}"#, statusCode: 401),
            .json(#"{"error":"The access token is invalid"}"#, statusCode: 401),
        ])

        let error = await #expect(throws: MastodonAPIError.self) { try await makeEndpoint(transport).url() }
        #expect(error?.isUnauthorized == true)
    }
}
