import Foundation
import SciaCore
import Synchronization
import Testing
@testable import Scia

@MainActor
@Suite(.serialized)
struct FeedTimelineControllerTests {
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
        feed: TimelineFeed = .home,
        transport: some HTTPTransport,
        connector: some WebSocketConnector = MessageQueueConnector(),
        tuning: TuningStore = TuningStore(defaults: nil),
        onUnauthorized: @escaping () -> Void = {}
    ) throws -> FeedTimelineController {
        let credential = try makeCredential()
        let client = MastodonClient(credential: credential, transport: transport)
        let streaming = StreamingClient(credential: credential, connector: connector)
        let streamingEndpoint = StreamingEndpoint(client: client)
        let streamingHub = StreamingHub(livePolicy: { TuningCatalog.liveUpdates(in: tuning) }) {
            streaming.open(baseURL: try await streamingEndpoint.url())
        }
        return FeedTimelineController(
            feed: feed,
            client: client,
            streamingHub: streamingHub,
            tuning: tuning,
            onUnauthorized: onUnauthorized
        )
    }

    /// 投稿を、ストリーミングの`update`イベントのテキストにする。
    private func updateMessage(_ status: Status, stream: [String] = ["user"]) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let payload = String(decoding: try encoder.encode(status), as: UTF8.self)
        let envelope = try JSONSerialization.data(withJSONObject: ["stream": stream, "event": "update", "payload": payload])
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
        let controller = try makeController(transport: transport) {
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

    /// ローカルは公開タイムラインを読み、`public:local`の新着を挿入する。markerはホームと通知にしかないため、既読位置は読まず保存もしない。
    @Test func localFeedReadsPublicTimelineAndSkipsMarkers() async throws {
        let existing = StatusFactory.make(count: 3, startingAt: 100)
        let arriving = StatusFactory.make(count: 1, startingAt: 200)
        let transport = try HomeTransport(home: existing, servesMarkers: false)
        let connector = MessageQueueConnector()
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(0.2, for: TuningCatalog.insertionInterval)
        let controller = try makeController(feed: .local, transport: transport, connector: connector, tuning: tuning)
        defer { controller.stop() }

        controller.start()
        try await waitUntil { connector.isConnected }
        #expect(controller.viewController.displayedStatusIDs == existing.map(\.id))
        connector.send(try updateMessage(try #require(arriving.first), stream: ["public:local"]))
        try await waitUntil { controller.viewController.displayedStatusIDs.count == 4 }
        controller.enterBackground()

        #expect(controller.viewController.displayedStatusIDs == (arriving + existing).map(\.id))
        #expect(transport.publicQueries.allSatisfy { $0.contains(URLQueryItem(name: "local", value: "true")) })
        #expect(!transport.publicQueries.isEmpty)
    }

    @Test func savedMarkerSetsUnreadCount() async throws {
        let statuses = StatusFactory.make(count: 5, startingAt: 100)
        let transport = try HomeTransport(home: statuses, markerID: statuses[3].id)
        let controller = try makeController(transport: transport)
        defer { controller.stop() }

        controller.start()
        try await waitUntil { controller.viewController.contentState == .loaded }

        #expect(controller.viewController.unreadCount == 3)
    }

    @Test func emptyHomeReconnectsWhenReturningToForeground() async throws {
        let connector = MessageQueueConnector()
        let controller = try makeController(transport: try HomeTransport(home: []), connector: connector)
        defer { controller.stop() }

        controller.start()
        try await waitUntil { connector.connectionCount == 1 }
        controller.enterBackground()
        controller.enterForeground()

        try await waitUntil { connector.connectionCount == 2 }
    }

    @Test func backgroundDuringInitialLoadDefersConnection() async throws {
        let gate = ResponseGate()
        let home = try HomeTransport(home: StatusFactory.make(count: 3, startingAt: 100))
        let transport = ScriptedTransport { request in
            if request.url?.path() == "/api/v1/timelines/home" {
                await gate.wait()
            }
            do {
                let (body, response) = try await home.send(request)
                return (response.statusCode, body)
            } catch {
                return (500, Data())
            }
        }
        let connector = MessageQueueConnector()
        let controller = try makeController(transport: transport, connector: connector)
        defer { controller.stop() }

        controller.start()
        await gate.waitUntilWaiting()
        controller.enterBackground()
        await gate.open()
        try await waitUntil { controller.viewController.contentState == .loaded }
        try await Task.sleep(for: .milliseconds(100))
        #expect(connector.connectionCount == 0, "バックグラウンドのまま接続しました")

        controller.enterForeground()
        try await waitUntil { connector.connectionCount == 1 }
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
private final class HomeTransport: HTTPTransport {
    let homeBody: Data
    let markerBody: Data
    /// falseなら、markerを読み書きしたときにテストを失敗させる。markerのない一覧のテストに使う。
    let servesMarkers: Bool
    private let recordedPublicQueries = Mutex<[[URLQueryItem]]>([])
    /// 公開タイムラインを読んだときのクエリ。
    var publicQueries: [[URLQueryItem]] { recordedPublicQueries.withLock { $0 } }

    /// - Parameter home: ホームと公開タイムラインの最初のページ。
    init(home: [Status], markerID: String? = nil, servesMarkers: Bool = true) throws {
        self.servesMarkers = servesMarkers
        markerBody = Data((markerID.map { #"{"home":{"last_read_id":"\#($0)","version":1,"updated_at":"2026-10-13T03:21:45.123Z"}}"# } ?? "{}").utf8)
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
        case "/api/v1/timelines/public":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            recordedPublicQueries.withLock { $0.append(query) }
            body = homeBody
        case "/api/v1/markers":
            if !servesMarkers {
                Issue.record("markerのない一覧でmarkerを読み書きしました: \(url)")
            }
            body = markerBody
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
    var connectionCount: Int { state.withLock { $0.connections } }

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

        /// 購読の申し込みは確かめないので捨てる。届けるイベントは`MessageQueueConnector.send`で決める。
        func send(_ text: String) async throws {}

        func ping() async throws {}

        func close() {
            owner.close()
        }
    }
}
