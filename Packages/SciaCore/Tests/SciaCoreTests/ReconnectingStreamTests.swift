import Foundation
import Synchronization
import Testing
@testable import SciaCore

struct ReconnectingStreamTests {
    /// 待ち時間を短くして、テストが実時間で終わるようにする。
    private static let fastPolicy = ReconnectingStream.Policy(
        initialRetryDelay: .milliseconds(10),
        maxRetryDelay: .milliseconds(40),
        pingInterval: .seconds(3600),
        pingTimeout: .seconds(5)
    )

    private static let deleteOne = #"{"stream":["user"],"event":"delete","payload":"1"}"#
    private static let deleteTwo = #"{"stream":["user"],"event":"delete","payload":"2"}"#

    @Test func reconnectsWithBackoffAndReportsEachConnection() async throws {
        let connector = ScriptedConnector([
            .init(messages: [Self.deleteOne], afterMessages: .drop),
            .init(handshake: .fail(URLError(.cannotConnectToHost))),
            .init(messages: [Self.deleteTwo]),
        ])
        let log = ActivityLog()
        let stream = makeStream(connector, policy: Self.fastPolicy)

        let task = Task { try await stream.run { await log.append($0) } }
        await log.waitUntil(count: 6)
        task.cancel()
        _ = await task.result

        #expect(await log.labels == [
            "connected",
            "event delete 1",
            "disconnected after 10ms",
            "disconnected after 20ms",
            "connected",
            "event delete 2",
        ])
        #expect(connector.closedCount == 3, "切れた接続か取り消した接続が閉じられていません")
    }

    @Test func retryDelayDoublesUpToMaximum() {
        let policy = Self.fastPolicy
        #expect((1...5).map { policy.retryDelay(afterFailures: $0) } == [
            .milliseconds(10), .milliseconds(20), .milliseconds(40), .milliseconds(40), .milliseconds(40),
        ])
    }

    /// ストリーミングだけが401を返すサーバーもあるため、トークンが無効かどうかは呼び出し側が確かめる。ここでは知らせてつなぎ直しを続ける。
    @Test func unauthorizedHandshakeIsReportedAndRetried() async throws {
        let connector = ScriptedConnector([
            .init(handshake: .fail(MastodonAPIError(statusCode: 401, message: "Unauthorized"))),
            .init(messages: [Self.deleteOne]),
        ])
        let log = ActivityLog()
        let stream = makeStream(connector, policy: Self.fastPolicy)

        let task = Task { try await stream.run { await log.append($0) } }
        await log.waitUntil(count: 4)
        task.cancel()
        _ = await task.result

        #expect(await log.labels == ["unauthorized", "disconnected after 10ms", "connected", "event delete 1"])
    }

    @Test func unansweredPingIsTreatedAsDisconnection() async throws {
        let connector = ScriptedConnector([
            .init(answeredPings: 1),
            .init(),
        ])
        let log = ActivityLog()
        var policy = Self.fastPolicy
        policy.pingInterval = .milliseconds(20)
        policy.pingTimeout = .milliseconds(50)
        let stream = makeStream(connector, policy: policy)

        let task = Task { try await stream.run { await log.append($0) } }
        await log.waitUntil(count: 3)
        task.cancel()
        _ = await task.result

        #expect(await log.labels == ["connected", "disconnected after 10ms", "connected"])
        #expect(await log.reasons.first == "PingTimeout")
    }

    /// URLSessionWebSocketTaskは未読のメッセージの後ろにあるpingの応答を遅らせるため、最初のメッセージでも成立とみなす。
    @Test func firstMessageCountsAsConnectedBeforePingIsAnswered() async throws {
        let connector = ScriptedConnector([.init(messages: [Self.deleteOne], answeredPings: 0)])
        let log = ActivityLog()
        let stream = makeStream(connector, policy: Self.fastPolicy)

        let task = Task { try await stream.run { await log.append($0) } }
        await log.waitUntil(count: 2)
        task.cancel()
        _ = await task.result

        #expect(await log.labels == ["connected", "event delete 1"])
    }

    @Test func cancellationClosesConnectionAndEnds() async throws {
        let connector = ScriptedConnector([.init()])
        let log = ActivityLog()
        let stream = makeStream(connector, policy: Self.fastPolicy)

        let task = Task { try await stream.run { await log.append($0) } }
        await log.waitUntil(count: 1)
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(connector.closedCount == 1)
    }

    private func makeStream(_ connector: ScriptedConnector, policy: ReconnectingStream.Policy) -> ReconnectingStream {
        let client = StreamingClient(
            credential: Credential(
                instance: URL(filePath: "/"),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            connector: connector
        )
        return ReconnectingStream(policy: policy) {
            client.open(.user, baseURL: URL(filePath: "/"))
        }
    }
}

/// 届いた活動を記録し、決まった数に達するまで待てるようにする。
private actor ActivityLog {
    private var activities: [ReconnectingStream.Activity] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ activity: ReconnectingStream.Activity) {
        activities.append(activity)
        let ready = waiters.filter { $0.count <= activities.count }
        waiters.removeAll { $0.count <= activities.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitUntil(count: Int) async {
        if activities.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    var labels: [String] {
        activities.map { activity in
            switch activity {
            case .connected: "connected"
            case .unauthorized: "unauthorized"
            case .event(.delete(let id)): "event delete \(id)"
            case .event(let event): "event \(event)"
            case .disconnected(_, let delay): "disconnected after \(delay.components.attoseconds / 1_000_000_000_000_000)ms"
            }
        }
    }

    var reasons: [String] {
        activities.compactMap { activity in
            if case .disconnected(let reason, _) = activity { reason } else { nil }
        }
    }
}

/// 接続ごとに、ハンドシェイクの成否、届くメッセージ、その後の振る舞いを決めておけるWebSocketConnector。
/// 台本を使い切った後の接続は、何も届かず黙ったままにする。
final class ScriptedConnector: WebSocketConnector {
    struct Script: Sendable {
        enum Handshake: Sendable {
            case succeed
            case fail(any Error)
        }

        enum AfterMessages: Sendable {
            /// 何も届かないまま接続が続く。
            case stay
            /// 接続が切れる。
            case drop
        }

        var handshake: Handshake = .succeed
        var messages: [String] = []
        var afterMessages: AfterMessages = .stay
        /// これを超えたpingには応答しない。ハンドシェイクの確認のpingも数える。
        var answeredPings = Int.max
    }

    private let state: Mutex<(scripts: [Script], connectCount: Int, closedCount: Int)>

    init(_ scripts: [Script]) {
        state = Mutex((scripts, 0, 0))
    }

    var connectCount: Int { state.withLock { $0.connectCount } }
    var closedCount: Int { state.withLock { $0.closedCount } }

    func connect(_ request: URLRequest) -> any WebSocketConnection {
        let script = state.withLock { state in
            state.connectCount += 1
            return state.scripts.isEmpty ? Script() : state.scripts.removeFirst()
        }
        return ScriptedConnection(script: script) { [weak self] in
            self?.state.withLock { $0.closedCount += 1 }
        }
    }
}

private final class ScriptedConnection: WebSocketConnection {
    private struct State {
        var script: ScriptedConnector.Script
        var pings = 0
        var isClosed = false
        var waiters: [CheckedContinuation<Void, any Error>] = []
    }

    private let state: Mutex<State>
    private let onClose: @Sendable () -> Void

    init(script: ScriptedConnector.Script, onClose: @escaping @Sendable () -> Void) {
        state = Mutex(State(script: script))
        self.onClose = onClose
    }

    func receive() async throws -> String {
        enum Next { case message(String), fail(any Error), wait }
        let next: Next = state.withLock { state in
            if state.isClosed { return .fail(URLError(.cancelled)) }
            if case .fail(let error) = state.script.handshake { return .fail(error) }
            if !state.script.messages.isEmpty { return .message(state.script.messages.removeFirst()) }
            if case .drop = state.script.afterMessages { return .fail(URLError(.networkConnectionLost)) }
            return .wait
        }
        switch next {
        case .message(let message):
            return message
        case .fail(let error):
            throw error
        case .wait:
            try await waitUntilClosed()
            throw URLError(.cancelled)
        }
    }

    func ping() async throws {
        let answers: Result<Bool, any Error> = state.withLock { state in
            if state.isClosed { return .failure(URLError(.cancelled)) }
            if case .fail(let error) = state.script.handshake { return .failure(error) }
            state.pings += 1
            return .success(state.pings <= state.script.answeredPings)
        }
        if try answers.get() { return }
        try await waitUntilClosed()
        throw URLError(.cancelled)
    }

    func close() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>]? in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        guard let waiters else { return }
        onClose()
        waiters.forEach { $0.resume(throwing: URLError(.cancelled)) }
    }

    private func waitUntilClosed() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let isClosed = state.withLock { state in
                if !state.isClosed { state.waiters.append(continuation) }
                return state.isClosed
            }
            if isClosed {
                continuation.resume(throwing: URLError(.cancelled))
            }
        }
    }
}
