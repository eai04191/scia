import Foundation
import Synchronization
import SciaTesting
import Testing
@testable import SciaCore

struct StreamingMessageDecoderTests {
    private func fixtureText(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func decodesUpdateWithStringifiedStatus() throws {
        let event = try StreamingMessageDecoder.decode(try fixtureText("streaming_update")).event

        guard case .update(let status) = event else {
            Issue.record("updateになりませんでした: \(event)")
            return
        }
        #expect(status.id == "113000000000000001")
        #expect(status.account.username == "alice")
    }

    @Test func decodesStatusUpdate() throws {
        let event = try StreamingMessageDecoder.decode(try fixtureText("streaming_status_update")).event

        guard case .statusUpdate(let status) = event else {
            Issue.record("status.updateになりませんでした: \(event)")
            return
        }
        #expect(status.content == "<p>編集後</p>")
    }

    @Test func decodesDeleteWhosePayloadIsBareID() throws {
        let message = try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"delete","payload":"106692867363994015"}"#)

        #expect(message == StreamingMessage(stream: ["user"], event: .delete(statusID: "106692867363994015")))
    }

    @Test func decodesFiltersChangedWithoutPayload() throws {
        #expect(try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"filters_changed"}"#).event == .filtersChanged)
    }

    @Test func decodesNotificationWithStringifiedPayload() throws {
        let payload = #"{"id":"34975865","type":"reblog","created_at":"2026-10-13T03:26:00.000Z","account":{"id":"2","username":"bob","acct":"bob","display_name":"Bob","avatar":"https://example.social/avatars/bob.png","avatar_static":"https://example.social/avatars/bob.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@bob","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]},"status":{"id":"113000000000000001","created_at":"2026-10-13T03:21:45.123Z","spoiler_text":"","url":null,"content":"<p>Hello</p>","account":{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@alice","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]},"mentions":[],"tags":[],"emojis":[],"media_attachments":[],"sensitive":false}}"#
        let envelope = try JSONSerialization.data(withJSONObject: ["stream": ["user:notification"], "event": "notification", "payload": payload])

        let event = try StreamingMessageDecoder.decode(String(decoding: envelope, as: UTF8.self)).event

        guard case .notification(let notification) = event else {
            Issue.record("notificationになりませんでした: \(event)")
            return
        }
        #expect(notification.id == "34975865")
        #expect(notification.type == .reblog)
        #expect(notification.status?.id == "113000000000000001")
    }

    @Test func keepsNameOfUnhandledEvent() throws {
        let event = try StreamingMessageDecoder.decode(#"{"stream":["user"],"event":"announcement","payload":"{}"}"#).event

        #expect(event == .unhandled(name: "announcement"))
    }

    @Test func throwsServerError() {
        #expect(throws: StreamingServerError(message: "Unknown stream type", status: 400)) {
            try StreamingMessageDecoder.decode(#"{"error":"Unknown stream type","status":400}"#)
        }
    }

    @Test func keepsStreamWithParameter() throws {
        let message = try StreamingMessageDecoder.decode(#"{"stream":["list","42"],"event":"delete","payload":"1"}"#)

        #expect(message.stream == ["list", "42"])
    }

    /// 1本の接続で複数を購読するため、どの購読のものか分からないイベントは配れない。
    @Test func eventWithoutStreamIsAnError() {
        #expect(throws: DecodingError.self) {
            try StreamingMessageDecoder.decode(#"{"event":"delete","payload":"1"}"#)
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

    @Test func opensWithoutStreamWithBearerToken() async throws {
        let connector = StubWebSocketConnector(messages: [])
        let client = StreamingClient(credential: try makeCredential(), connector: connector)

        _ = try await client.open(baseURL: try #require(URL(string: "wss://streaming.example.social")))

        let request = try #require(connector.requests.first)
        #expect(request.url?.absoluteString == "wss://streaming.example.social/api/v1/streaming")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func sendsSubscribeAndUnsubscribe() async throws {
        let connector = StubWebSocketConnector(messages: [])
        let connection = try await StreamingClient(credential: try makeCredential(), connector: connector)
            .open(baseURL: try #require(URL(string: "wss://streaming.example.social")))

        try await connection.subscribe(.user)
        try await connection.unsubscribe(.user)

        #expect(connector.sent == [
            #"{"stream":"user","type":"subscribe"}"#,
            #"{"stream":"user","type":"unsubscribe"}"#,
        ])
    }

    @Test func skipsUndecodableMessages() async throws {
        let connector = StubWebSocketConnector(messages: [
            "not json",
            #"{"stream":["user"],"event":"update","payload":"{\"broken\":true}"}"#,
            #"{"stream":["user"],"event":"delete","payload":"1"}"#,
        ])
        let connection = try await StreamingClient(credential: try makeCredential(), connector: connector)
            .open(baseURL: try #require(URL(string: "wss://streaming.example.social")))

        #expect(try await connection.next().event == .delete(statusID: "1"))
    }

    /// つなぐときに429や503で断られたら、示された再開までの長さをREST APIと同じエラーで返し、アカウントの自動の通信も止める。
    @Test func rejectedHandshakeCarriesResumeTimeAndPausesAccount() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = RateLimitGate(now: { now }, clock: TestClock())
        let connector = ScriptedConnector([.init(handshake: .fail(WebSocketHandshakeRejected(statusCode: 429, headers: ["retry-after": "30"])))])
        let connection = try await StreamingClient(credential: try makeCredential(), connector: connector, rateLimit: gate, now: { now })
            .open(baseURL: try #require(URL(string: "wss://streaming.example.social")))

        let error = await #expect(throws: MastodonAPIError.self) { try await connection.next() }
        #expect(error?.statusCode == 429)
        #expect(error?.retryAfter == .seconds(30))
        #expect(await gate.pausedUntil == now.addingTimeInterval(30))
    }

    /// トークンが無効なときは401で断られる。ログインし直しを促せるよう、REST APIと同じエラーにする。
    @Test func unauthorizedHandshakeIsReportedAsAPIError() async throws {
        let connector = ScriptedConnector([.init(handshake: .fail(WebSocketHandshakeRejected(statusCode: 401)))])
        let connection = try await StreamingClient(credential: try makeCredential(), connector: connector)
            .open(baseURL: try #require(URL(string: "wss://streaming.example.social")))

        let error = await #expect(throws: MastodonAPIError.self) { try await connection.ping() }
        #expect(error?.isUnauthorized == true)
    }

    /// 止められている間は、自動のつなぎ直しを送らない。使う人の操作でつなぐときは送る。
    @Test func doesNotConnectAutomaticallyWhilePaused() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = RateLimitGate(now: { now }, clock: TestClock())
        await gate.pause(until: now.addingTimeInterval(60))
        let connector = StubWebSocketConnector(messages: [])
        let client = StreamingClient(credential: try makeCredential(), connector: connector, rateLimit: gate, now: { now })
        let url = try #require(URL(string: "wss://streaming.example.social"))

        let error = await #expect(throws: AutomaticRequestsPaused.self) {
            try await RequestPurpose.$current.withValue(.display) { _ = try await client.open(baseURL: url) }
        }
        #expect(error?.retryAfter == .seconds(60))
        #expect(connector.requests.isEmpty)

        _ = try await client.open(baseURL: url)
        #expect(connector.requests.count == 1)
    }

    @Test func serverErrorEndsConnection() async throws {
        let connector = StubWebSocketConnector(messages: [#"{"error":"Unknown stream type","status":400}"#])
        let connection = try await StreamingClient(credential: try makeCredential(), connector: connector)
            .open(baseURL: try #require(URL(string: "wss://streaming.example.social")))

        await #expect(throws: StreamingServerError.self) { try await connection.next() }
    }
}

/// 登録したメッセージを順に返し、尽きたら接続が切れたものとして投げる。
final class StubWebSocketConnector: WebSocketConnector {
    private let state: Mutex<(messages: [String], requests: [URLRequest], sent: [String])>

    init(messages: [String]) {
        state = Mutex((messages, [], []))
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var sent: [String] { state.withLock { $0.sent } }

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

        func send(_ text: String) async throws {
            owner.state.withLock { $0.sent.append(text) }
        }

        func ping() async throws {}

        func close() {}
    }
}
