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
            client.open(baseURL: URL(filePath: "/"))
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
            case .event(let message):
                if case .delete(let id) = message.event { "event delete \(id)" } else { "event \(message.event)" }
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
        /// 送ったメッセージが記録されるまでの遅れ。送信がpingより遅れる経路を再現する。
        var sendDelay: Duration = .zero
        /// 最初のメッセージを届けるまでの遅れ。つながったあとの操作の途中にメッセージが届く経路を再現する。
        var firstMessageDelay: Duration = .zero
        /// `afterMessages`が`.drop`のとき、メッセージを届け終えてから切れるまでの遅れ。切れる前に、届いたメッセージに応じた送信を始めさせる。
        var dropDelay: Duration = .zero
        /// 開くまで、最初のメッセージを届けない。遅れの長さではなく、テストが条件を確かめてから届ける。
        var firstMessageGate: Gate?
        /// 送るメッセージごとに、開くまで送り終えない。遅れの長さではなく、テストが条件を確かめてから送り終える。
        var sendGates: [String: Gate] = [:]
    }

    /// 開くまで、待っている相手を止めておく。開いた後に待つ相手は止めない。
    final class Gate: Sendable {
        private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

        func open() {
            let waiters = state.withLock { state in
                state.isOpen = true
                defer { state.waiters.removeAll() }
                return state.waiters
            }
            waiters.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let isOpen = state.withLock { state in
                    if !state.isOpen { state.waiters.append(continuation) }
                    return state.isOpen
                }
                if isOpen {
                    continuation.resume()
                }
            }
        }
    }

    private let state: Mutex<(scripts: [Script], connectCount: Int, closedCount: Int, sent: [[String]])>

    init(_ scripts: [Script]) {
        state = Mutex((scripts, 0, 0, []))
    }

    var connectCount: Int { state.withLock { $0.connectCount } }
    var closedCount: Int { state.withLock { $0.closedCount } }
    /// 接続ごとに、送られたメッセージ。
    var sent: [[String]] { state.withLock { $0.sent } }

    func connect(_ request: URLRequest) -> any WebSocketConnection {
        let (script, index) = state.withLock { state in
            state.connectCount += 1
            state.sent.append([])
            return (state.scripts.isEmpty ? Script() : state.scripts.removeFirst(), state.sent.count - 1)
        }
        return ScriptedConnection(script: script) { [weak self] in
            self?.state.withLock { $0.closedCount += 1 }
        } onSend: { [weak self] text in
            self?.state.withLock { $0.sent[index].append(text) }
        }
    }
}

private final class ScriptedConnection: WebSocketConnection {
    private struct State {
        var script: ScriptedConnector.Script
        var hasDeliveredMessage = false
        var pings = 0
        var isClosed = false
        var waiters: [CheckedContinuation<Void, any Error>] = []
    }

    private let state: Mutex<State>
    private let onClose: @Sendable () -> Void
    private let onSend: @Sendable (String) -> Void

    init(script: ScriptedConnector.Script, onClose: @escaping @Sendable () -> Void, onSend: @escaping @Sendable (String) -> Void) {
        state = Mutex(State(script: script))
        self.onClose = onClose
        self.onSend = onSend
    }

    func send(_ text: String) async throws {
        let (isClosed, delay, gate) = state.withLock { ($0.isClosed, $0.script.sendDelay, $0.script.sendGates[text]) }
        if isClosed { throw URLError(.cancelled) }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        await gate?.wait()
        onSend(text)
    }

    func receive() async throws -> String {
        enum Next { case message(String, after: Duration, gate: ScriptedConnector.Gate?), fail(any Error), drop(after: Duration), wait }
        let next: Next = state.withLock { state in
            if state.isClosed { return .fail(URLError(.cancelled)) }
            if case .fail(let error) = state.script.handshake { return .fail(error) }
            if !state.script.messages.isEmpty {
                let delay = state.hasDeliveredMessage ? .zero : state.script.firstMessageDelay
                let gate = state.hasDeliveredMessage ? nil : state.script.firstMessageGate
                state.hasDeliveredMessage = true
                return .message(state.script.messages.removeFirst(), after: delay, gate: gate)
            }
            if case .drop = state.script.afterMessages { return .drop(after: state.script.dropDelay) }
            return .wait
        }
        switch next {
        case .message(let message, let delay, let gate):
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            await gate?.wait()
            return message
        case .fail(let error):
            throw error
        case .drop(let delay):
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            throw URLError(.networkConnectionLost)
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
