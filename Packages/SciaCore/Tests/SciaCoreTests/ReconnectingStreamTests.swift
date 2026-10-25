import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

struct ReconnectingStreamTests {
    /// 待ち時間は手で進める時計で数えるので、長さは結果の確かめやすさで決める。
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
        let clock = TestClock()
        let stream = makeStream(connector, policy: Self.fastPolicy, clock: clock)

        let task = Task { try await stream.run { await log.append($0) } }
        // 切れたと知らせてから、つなぎ直すまで時計で待ち始めたのを確かめて、その分だけ進める。
        try await waitUntil { await log.count == 3 && clock.sleeperCount(dueWithin: .milliseconds(10)) == 1 }
        clock.advance(by: .milliseconds(10))
        try await waitUntil { await log.count == 4 && clock.sleeperCount(dueWithin: .milliseconds(20)) == 1 }
        clock.advance(by: .milliseconds(20))
        try await log.waitUntil(count: 6)
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
        let clock = TestClock()
        let stream = makeStream(connector, policy: Self.fastPolicy, clock: clock)

        let task = Task { try await stream.run { await log.append($0) } }
        try await waitUntil { await log.count == 2 && clock.sleeperCount(dueWithin: .milliseconds(10)) == 1 }
        clock.advance(by: .milliseconds(10))
        try await log.waitUntil(count: 4)
        task.cancel()
        _ = await task.result

        #expect(await log.labels == ["unauthorized", "disconnected after 10ms", "connected", "event delete 1"])
    }

    /// つなぐときの応答が429や503で再開の時刻を示したら、自分の間隔より遅くても、その時刻まではつなぎ直さない。
    @Test(arguments: [
        MastodonAPIError(statusCode: 429, message: "Too Many Requests", retryAfter: .milliseconds(300)) as any Error & Sendable,
        AutomaticRequestsPaused(until: Date(timeIntervalSince1970: 1_800_000_000), retryAfter: .milliseconds(300)),
    ])
    func waitsUntilServerSaysToResume(error: any Error & Sendable) async throws {
        let connector = ScriptedConnector([
            .init(handshake: .fail(error)),
            .init(messages: [Self.deleteOne]),
        ])
        let log = ActivityLog()
        let clock = TestClock()
        let stream = makeStream(connector, policy: Self.fastPolicy, clock: clock)

        let task = Task { try await stream.run { await log.append($0) } }
        try await waitUntil { await log.count == 1 && clock.sleeperCount(dueWithin: .milliseconds(300)) == 1 }
        #expect(clock.sleeperCount(dueWithin: .milliseconds(299)) == 0, "再開の時刻より前につなぎ直そうとしています")
        clock.advance(by: .milliseconds(300))
        try await log.waitUntil(count: 3)
        task.cancel()
        _ = await task.result

        #expect(await log.labels == ["disconnected after 300ms", "connected", "event delete 1"])
    }

    @Test func unansweredPingIsTreatedAsDisconnection() async throws {
        let connector = ScriptedConnector([
            .init(answeredPings: 1),
            .init(),
        ])
        let log = ActivityLog()
        let clock = TestClock()
        var policy = Self.fastPolicy
        policy.pingInterval = .milliseconds(20)
        let stream = makeStream(connector, policy: policy, clock: clock)

        let task = Task { try await stream.run { await log.append($0) } }
        // つながって次のpingを待ち始めたら、次のpingまで進める。
        try await waitUntil { await log.count == 1 && clock.sleeperCount(dueWithin: .milliseconds(20)) == 1 }
        clock.advance(by: .milliseconds(20))
        // 応答しないpingが時間切れを待ち始めたら、時間切れまで進める。応答するpingの時間切れは、応答すると取り消される。
        try await waitUntil { connector.unansweredPings == 1 && clock.sleeperCount(dueWithin: policy.pingTimeout) == 1 }
        clock.advance(by: policy.pingTimeout)
        try await waitUntil { await log.count == 2 && clock.sleeperCount(dueWithin: .milliseconds(10)) == 1 }
        clock.advance(by: .milliseconds(10))
        try await log.waitUntil(count: 3)
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
        try await log.waitUntil(count: 2)
        task.cancel()
        _ = await task.result

        #expect(await log.labels == ["connected", "event delete 1"])
    }

    @Test func cancellationClosesConnectionAndEnds() async throws {
        let connector = ScriptedConnector([.init()])
        let log = ActivityLog()
        let stream = makeStream(connector, policy: Self.fastPolicy)

        let task = Task { try await stream.run { await log.append($0) } }
        try await log.waitUntil(count: 1)
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(connector.closedCount == 1)
    }

    /// 待つ時間はすべて`clock`で数える。進めなければ、つなぎ直しもpingの時間切れも起きない。
    private func makeStream(
        _ connector: ScriptedConnector,
        policy: ReconnectingStream.Policy,
        clock: TestClock = TestClock()
    ) -> ReconnectingStream {
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
        return ReconnectingStream(policy: policy, clock: clock) {
            try await client.open(baseURL: URL(filePath: "/"))
        }
    }
}

/// 届いた活動を記録し、決まった数に達するまで待てるようにする。
private actor ActivityLog {
    private var activities: [ReconnectingStream.Activity] = []

    func append(_ activity: ReconnectingStream.Activity) {
        activities.append(activity)
    }

    var count: Int { activities.count }

    func waitUntil(count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await SciaTesting.waitUntil({ activities.count >= count }, sourceLocation: sourceLocation)
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
/// シナリオを使い切った後の接続は、何も届かず黙ったままにする。
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
        /// `afterMessages`が`.drop`のとき、開くまで切らない。遅れの長さではなく、テストが条件を確かめてから切る。
        var dropGate: Gate?
        /// 開くまで、最初のメッセージを届けない。遅れの長さではなく、テストが条件を確かめてから届ける。
        var firstMessageGate: Gate?
        /// 送るメッセージごとに、開くまで送り終えない。遅れの長さではなく、テストが条件を確かめてから送り終える。
        var sendGates: [String: Gate] = [:]
    }

    private let state: Mutex<(scripts: [Script], connectCount: Int, closedCount: Int, sent: [[String]], unansweredPings: Int)>

    init(_ scripts: [Script]) {
        state = Mutex((scripts, 0, 0, [], 0))
    }

    var connectCount: Int { state.withLock { $0.connectCount } }
    var closedCount: Int { state.withLock { $0.closedCount } }
    /// 接続ごとに、送られたメッセージ。
    var sent: [[String]] { state.withLock { $0.sent } }
    /// 応答しないまま、接続が閉じるのを待っているpingの数。閉じたら、その接続の分を同時に減らす。
    var unansweredPings: Int { state.withLock { $0.unansweredPings } }

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
        } onUnansweredPings: { [weak self] change in
            self?.state.withLock { $0.unansweredPings += change }
        }
    }
}

private final class ScriptedConnection: WebSocketConnection {
    private struct State {
        var script: ScriptedConnector.Script
        var hasDeliveredMessage = false
        var pings = 0
        var unansweredPings = 0
        var isClosed = false
        var waiters: [CheckedContinuation<Void, any Error>] = []
    }

    private let state: Mutex<State>
    private let onClose: @Sendable () -> Void
    private let onSend: @Sendable (String) -> Void
    private let onUnansweredPings: @Sendable (Int) -> Void

    init(
        script: ScriptedConnector.Script,
        onClose: @escaping @Sendable () -> Void,
        onSend: @escaping @Sendable (String) -> Void,
        onUnansweredPings: @escaping @Sendable (Int) -> Void
    ) {
        state = Mutex(State(script: script))
        self.onClose = onClose
        self.onSend = onSend
        self.onUnansweredPings = onUnansweredPings
    }

    func send(_ text: String) async throws {
        let (isClosed, gate) = state.withLock { ($0.isClosed, $0.script.sendGates[text]) }
        if isClosed { throw URLError(.cancelled) }
        try await gate?.wait()
        onSend(text)
    }

    func receive() async throws -> String {
        enum Next { case message(String, gate: Gate?), fail(any Error), drop(gate: Gate?), wait }
        let next: Next = state.withLock { state in
            if state.isClosed { return .fail(URLError(.cancelled)) }
            if case .fail(let error) = state.script.handshake { return .fail(error) }
            if !state.script.messages.isEmpty {
                let gate = state.hasDeliveredMessage ? nil : state.script.firstMessageGate
                state.hasDeliveredMessage = true
                return .message(state.script.messages.removeFirst(), gate: gate)
            }
            if case .drop = state.script.afterMessages { return .drop(gate: state.script.dropGate) }
            return .wait
        }
        switch next {
        case .message(let message, let gate):
            try await gate?.wait()
            return message
        case .fail(let error):
            throw error
        case .drop(let gate):
            try await gate?.wait()
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
            let answers = state.pings <= state.script.answeredPings
            if !answers {
                // 閉じるときの減らし方と順序がずれないよう、接続の状態と同じロックの中で数える。
                state.unansweredPings += 1
                onUnansweredPings(1)
            }
            return .success(answers)
        }
        if try answers.get() { return }
        try await waitUntilClosed()
        throw URLError(.cancelled)
    }

    func close() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>]? in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            onUnansweredPings(-state.unansweredPings)
            state.unansweredPings = 0
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
