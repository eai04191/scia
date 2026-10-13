import Foundation
import SciaCore
import Synchronization
import Testing
@testable import Scia

@MainActor
@Suite(.serialized)
struct HomeTimelineControllerTests {
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

    private func makeController(
        transport: some HTTPTransport,
        connector: some WebSocketConnector = MessageQueueConnector(),
        tuning: TuningStore = TuningStore(defaults: nil),
        onUnauthorized: @escaping (HomeTimelineController, String) -> Void = { _, _ in }
    ) throws -> HomeTimelineController {
        let credential = try makeCredential()
        return HomeTimelineController(
            client: MastodonClient(credential: credential, transport: transport),
            streaming: StreamingClient(credential: credential, connector: connector),
            tuning: tuning,
            onUnauthorized: onUnauthorized
        )
    }

    /// 投稿を、ストリーミングの`update`イベントのテキストにする。
    private func updateMessage(_ status: Status) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let payload = String(decoding: try encoder.encode(status), as: UTF8.self)
        let envelope = try JSONSerialization.data(withJSONObject: ["stream": ["user"], "event": "update", "payload": payload])
        return String(decoding: envelope, as: UTF8.self)
    }

    @Test func emptyRegeneratingHomeOffersReload() async throws {
        let transport = ScriptedTransport { _ in (206, Data("[]".utf8)) }
        let controller = try makeController(transport: transport)

        controller.start()
        try await waitUntil { controller.viewController.contentState != .loading }

        #expect(controller.viewController.contentState == .regenerating)
    }

    @Test func stoppedControllerDoesNotReportUnauthorized() async throws {
        let gate = ResponseGate()
        let transport = ScriptedTransport { _ in
            await gate.wait()
            return (401, Data(#"{"error":"The access token is invalid"}"#.utf8))
        }
        let reported = Box(false)
        let controller = try makeController(transport: transport) { _, _ in
            reported.value = true
        }

        controller.start()
        await gate.waitUntilWaiting()
        controller.stop()
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(!reported.value)
    }

    @Test func streamedUpdateIsInsertedAfterInterval() async throws {
        let existing = StatusFactory.make(count: 3, startingAt: 100)
        let arriving = StatusFactory.make(count: 1, startingAt: 200)
        let transport = try HomeTransport(home: existing)
        let connector = MessageQueueConnector()
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(0.2, for: TuningCatalog.insertionInterval)
        let controller = try makeController(transport: transport, connector: connector, tuning: tuning)
        defer { controller.stop() }

        controller.start()
        try await waitUntil { connector.isConnected }
        connector.send(try updateMessage(try #require(arriving.first)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.viewController.displayedStatusIDs == existing.map(\.id), "間隔を待たずに挿入されました")

        try await waitUntil { controller.viewController.displayedStatusIDs.count == 4 }
        #expect(controller.viewController.displayedStatusIDs == (arriving + existing).map(\.id))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "条件が満たされませんでした")
    }
}

@MainActor
private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// 応答をクロージャで組み立てるHTTPTransport。
private struct ScriptedTransport: HTTPTransport {
    let respond: @Sendable (URLRequest) async -> (Int, Data)

    init(_ respond: @escaping @Sendable (URLRequest) async -> (Int, Data)) {
        self.respond = respond
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (statusCode, body) = await respond(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
        return (body, response)
    }
}

/// 応答を途中で止めておくための門。
private actor ResponseGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            isWaiting = true
            arrival?.resume()
            arrival = nil
        }
    }

    func waitUntilWaiting() async {
        if isWaiting { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

/// ホームタイムラインには決まった投稿を、インスタンス情報にはストリーミングの接続先を返すHTTPTransport。
private struct HomeTransport: HTTPTransport {
    let homeBody: Data

    init(home: [Status]) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        homeBody = try encoder.encode(home)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let body: Data
        switch url.path() {
        case "/api/v1/timelines/home":
            body = homeBody
        case "/api/v2/instance":
            body = Data(#"{"configuration":{"urls":{"streaming":"wss://example.social"}}}"#.utf8)
        default:
            Issue.record("想定していないリクエストです: \(url)")
            body = Data()
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (body, response)
    }
}

/// テストから送ったメッセージを届けるWebSocketの接続。
final class MessageQueueConnector: WebSocketConnector {
    private let state = Mutex<(connections: Int, messages: [String], waiter: CheckedContinuation<String, any Error>?)>((0, [], nil))

    var isConnected: Bool { state.withLock { $0.connections > 0 } }

    func connect(_ request: URLRequest) -> any WebSocketConnection {
        state.withLock { $0.connections += 1 }
        return Connection(owner: self)
    }

    func send(_ message: String) {
        let waiter = state.withLock { state -> CheckedContinuation<String, any Error>? in
            guard let waiter = state.waiter else {
                state.messages.append(message)
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: message)
    }

    fileprivate func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let message = state.withLock { state -> String? in
                guard !state.messages.isEmpty else {
                    state.waiter = continuation
                    return nil
                }
                return state.messages.removeFirst()
            }
            if let message {
                continuation.resume(returning: message)
            }
        }
    }

    fileprivate func close() {
        let waiter = state.withLock { state in
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: URLError(.cancelled))
    }

    private struct Connection: WebSocketConnection {
        let owner: MessageQueueConnector

        func receive() async throws -> String {
            try await owner.receive()
        }

        func close() {
            owner.close()
        }
    }
}
