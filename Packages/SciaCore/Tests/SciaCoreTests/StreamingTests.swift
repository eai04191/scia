import Foundation
import Synchronization
import Testing
@testable import SciaCore

struct StreamingMessageDecoderTests {
    private func fixtureText(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func decodesUpdateWithStringifiedStatus() throws {
        let event = try StreamingMessageDecoder.decode(try fixtureText("streaming_update"))

        guard case .update(let status) = event else {
            Issue.record("updateになりませんでした: \(event)")
            return
        }
        #expect(status.id == "113000000000000001")
        #expect(status.account.username == "alice")
    }

    @Test func decodesStatusUpdate() throws {
        let event = try StreamingMessageDecoder.decode(try fixtureText("streaming_status_update"))

        guard case .statusUpdate(let status) = event else {
            Issue.record("status.updateになりませんでした: \(event)")
            return
        }
        #expect(status.content == "<p>編集後</p>")
    }

    @Test func decodesDeleteWhosePayloadIsBareID() throws {
        let event = try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"delete","payload":"106692867363994015"}"#)

        #expect(event == .delete(statusID: "106692867363994015"))
    }

    @Test func decodesFiltersChangedWithoutPayload() throws {
        #expect(try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"filters_changed"}"#) == .filtersChanged)
    }

    @Test func decodesNotificationWithStringifiedPayload() throws {
        let payload = #"{"id":"34975865","type":"reblog","created_at":"2026-10-13T03:26:00.000Z","account":{"id":"2","username":"bob","acct":"bob","display_name":"Bob","avatar":"https://example.social/avatars/bob.png","emojis":[]},"status":{"id":"113000000000000001","created_at":"2026-10-13T03:21:45.123Z","spoiler_text":"","url":null,"content":"<p>Hello</p>","account":{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","emojis":[]},"mentions":[],"tags":[],"emojis":[]}}"#
        let envelope = try JSONSerialization.data(withJSONObject: ["stream": ["user:notification"], "event": "notification", "payload": payload])

        let event = try StreamingMessageDecoder.decode(String(decoding: envelope, as: UTF8.self))

        guard case .notification(let notification) = event else {
            Issue.record("notificationになりませんでした: \(event)")
            return
        }
        #expect(notification.id == "34975865")
        #expect(notification.type == .reblog)
        #expect(notification.status?.id == "113000000000000001")
    }

    @Test func keepsNameOfUnhandledEvent() throws {
        let event = try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"announcement","payload":"{}"}"#)

        #expect(event == .unhandled(name: "announcement"))
    }

    @Test func throwsServerError() {
        #expect(throws: StreamingServerError(message: "Unknown stream type", status: 400)) {
            try StreamingMessageDecoder.decode(#"{"error":"Unknown stream type","status":400}"#)
        }
    }

    @Test func updateWithoutPayloadIsAnError() {
        #expect(throws: DecodingError.self) {
            try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"update"}"#)
        }
    }
}

struct StreamingClientTests {
    private func makeCredential() throws -> Credential {
        Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "1",
            username: "alice"
        )
    }

    @Test func opensUserStreamWithBearerToken() async throws {
        let connector = StubWebSocketConnector(messages: [])
        let client = StreamingClient(credential: try makeCredential(), connector: connector)

        _ = client.open(.user, baseURL: try #require(URL(string: "wss://streaming.example.social")))

        let request = try #require(connector.requests.first)
        #expect(request.url?.absoluteString == "wss://streaming.example.social/api/v1/streaming?stream=user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func skipsUndecodableMessages() async throws {
        let connector = StubWebSocketConnector(messages: [
            "not json",
            #"{"stream":["user"],"event":"update","payload":"{\"broken\":true}"}"#,
            #"{"stream":["user"],"event":"delete","payload":"1"}"#,
        ])
        let connection = StreamingClient(credential: try makeCredential(), connector: connector)
            .open(.user, baseURL: try #require(URL(string: "wss://streaming.example.social")))

        #expect(try await connection.next() == .delete(statusID: "1"))
    }

    @Test func serverErrorEndsConnection() async throws {
        let connector = StubWebSocketConnector(messages: [#"{"error":"Unknown stream type","status":400}"#])
        let connection = StreamingClient(credential: try makeCredential(), connector: connector)
            .open(.user, baseURL: try #require(URL(string: "wss://streaming.example.social")))

        await #expect(throws: StreamingServerError.self) { try await connection.next() }
    }
}

struct MastodonClientStreamingURLTests {
    @Test func readsStreamingURLFromInstance() async throws {
        let transport = StubTransport([try .fixture("instance_v2")])
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

        #expect(try await client.streamingURL().absoluteString == "wss://streaming.example.social")
        #expect(await transport.requests.first?.url?.absoluteString == "https://example.social/api/v2/instance")
    }
}

/// 登録したメッセージを順に返し、尽きたら接続が切れたものとして投げる。
final class StubWebSocketConnector: WebSocketConnector {
    private let state: Mutex<(messages: [String], requests: [URLRequest])>

    init(messages: [String]) {
        state = Mutex((messages, []))
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func connect(_ request: URLRequest) -> any WebSocketConnection {
        state.withLock { $0.requests.append(request) }
        return Connection(owner: self)
    }

    private struct Connection: WebSocketConnection {
        let owner: StubWebSocketConnector

        func receive() async throws -> String {
            try owner.state.withLock { state in
                guard !state.messages.isEmpty else { throw URLError(.networkConnectionLost) }
                return state.messages.removeFirst()
            }
        }

        func ping() async throws {}

        func close() {}
    }
}
