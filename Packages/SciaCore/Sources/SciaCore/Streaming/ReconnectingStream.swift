public import Foundation
import Synchronization

/// ストリーミングの接続を保ち、切れたら間をおいてつなぎ直す。
public struct ReconnectingStream: Sendable {
    /// 接続の状態の変化と、届いたイベント。
    public enum Activity: Sendable, Equatable {
        /// 接続が成立した。つなぎ直したときは、切れていた間の投稿をRESTで補う。
        case connected
        case event(StreamingMessage)
        /// 接続が401で断られた。トークンが無効かは呼び出し側が確かめる。この後に`disconnected`が続き、つなぎ直しも続ける。
        case unauthorized
        /// 接続が切れた、またはつながらなかった。`retryAfter`だけ待ってつなぎ直す。`reason`はログに書く説明で、応答の中身を含まない。
        case disconnected(reason: String, retryAfter: Duration)
    }

    public struct Policy: Sendable {
        /// 1回目の失敗の後に待つ時間。続けて失敗するたびに倍にする。
        public var initialRetryDelay: Duration
        public var maxRetryDelay: Duration
        /// 接続が生きているかを確かめる間隔。サーバーからイベントが来ないだけなのか、経路が切れたのかを区別する。
        public var pingInterval: Duration
        /// pingの応答をこの時間待っても返らなければ、切れたものとみなす。
        public var pingTimeout: Duration

        public init(initialRetryDelay: Duration, maxRetryDelay: Duration, pingInterval: Duration, pingTimeout: Duration) {
            self.initialRetryDelay = initialRetryDelay
            self.maxRetryDelay = maxRetryDelay
            self.pingInterval = pingInterval
            self.pingTimeout = pingTimeout
        }

        public static let standard = Policy(
            initialRetryDelay: .seconds(1),
            maxRetryDelay: .seconds(60),
            pingInterval: .seconds(30),
            pingTimeout: .seconds(10)
        )

        func retryDelay(afterFailures failures: Int) -> Duration {
            var delay = initialRetryDelay
            for _ in 1..<max(failures, 1) where delay < maxRetryDelay {
                delay *= 2
            }
            return min(delay, maxRetryDelay)
        }
    }

    /// pingの応答が時間内に返らなかった。
    public struct PingTimeout: Error, LocalizedError {
        public var errorDescription: String? { "ストリーミングサーバーから応答がありません" }
    }

    private let connect: @Sendable () async throws -> StreamingConnection
    private let policy: Policy
    private let clock: any Clock<Duration>
    private let waitForPingTimeout: @Sendable (Duration) async throws -> Void

    /// - Parameter clock: つなぎ直すまでと、次のpingまでと、pingの応答を待つ時間を数える。テストでは手で進める時計を渡す。
    public init(
        policy: Policy = .standard,
        clock: any Clock<Duration> = SystemTime.clock,
        connect: @escaping @Sendable () async throws -> StreamingConnection
    ) {
        self.init(policy: policy, clock: clock, waitForPingTimeout: { try await clock.sleep(for: $0) }, connect: connect)
    }

    /// - Parameter waitForPingTimeout: pingの応答を待つ時間を数える。返ったら時間切れにする。応答が先に返ったら取り消す。
    ///   テストで、時間切れにするpingを時間の長さではなく順番で決める。
    init(
        policy: Policy,
        clock: any Clock<Duration>,
        waitForPingTimeout: @escaping @Sendable (Duration) async throws -> Void,
        connect: @escaping @Sendable () async throws -> StreamingConnection
    ) {
        self.policy = policy
        self.clock = clock
        self.waitForPingTimeout = waitForPingTimeout
        self.connect = connect
    }

    /// キャンセルされるまで、接続とつなぎ直しを続ける。`handle`は届いた順に1つずつ呼ぶ。
    /// 401で断られても終わらない。ストリーミングだけが401を返すサーバーもあるため、`unauthorized`で知らせて、トークンが無効かは呼び出し側に任せる。
    public func run(_ handle: @escaping @Sendable (Activity) async -> Void) async throws {
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                let connection = try await connect()
                defer { connection.close() }
                try await withTaskCancellationHandler {
                    for try await activity in session(connection) {
                        if case .connected = activity {
                            failures = 0
                        }
                        await handle(activity)
                    }
                    // 列は失敗でだけ終わるため、ここへは来ない。来たら切れたものとしてつなぎ直す。
                    throw URLError(.networkConnectionLost)
                } onCancel: {
                    connection.close()
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
                    await handle(.unauthorized)
                }
                failures += 1
                let delay = policy.retryDelay(afterFailures: failures)
                await handle(.disconnected(reason: SciaLog.describe(error), retryAfter: delay))
                try await clock.sleep(for: delay)
            }
        }
    }

    /// 1つの接続の、成立とイベントを順に流す。受信かpingのどちらかが失敗したら、その失敗で終わる。
    ///
    /// 成立は、最初のpingの応答か最初のメッセージの早い方で判断する。URLSessionWebSocketTaskは、未読のメッセージがあると
    /// その後ろのpingの応答を受信するまで処理しないため、pingの応答だけを待つと、イベントが先に届いたときに時間切れになる。
    private func session(_ connection: StreamingConnection) -> AsyncThrowingStream<Activity, any Error> {
        let (activities, continuation) = AsyncThrowingStream<Activity, any Error>.makeStream()
        let queue = ActivityQueue(continuation)
        let policy = policy
        let waitForPingTimeout = waitForPingTimeout
        let clock = clock
        let receiving = Task {
            do {
                while true {
                    queue.event(try await connection.next())
                }
            } catch {
                queue.finish(throwing: error)
            }
        }
        let pinging = Task {
            do {
                try await Self.ping(connection, timeout: policy.pingTimeout, wait: waitForPingTimeout)
                queue.connected()
                while true {
                    try await clock.sleep(for: policy.pingInterval)
                    try await Self.ping(connection, timeout: policy.pingTimeout, wait: waitForPingTimeout)
                }
            } catch {
                queue.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            // 片方が失敗したら、もう片方が待っている受信やpingも投げて終わるよう、接続を閉じる。
            receiving.cancel()
            pinging.cancel()
            connection.close()
        }
        return activities
    }

    /// pingの応答を待つ。時間内に返らなければ`PingTimeout`を投げる。
    ///
    /// URLSessionWebSocketTaskのpingは取り消しに応じないため、応答を待つ処理は切り離して動かし、時間切れでは待つのだけをやめる。
    /// 呼び出し側がその後に接続を閉じるので、応答を待っていた処理もそこで終わる。
    private static func ping(
        _ connection: StreamingConnection,
        timeout: Duration,
        wait: @escaping @Sendable (Duration) async throws -> Void
    ) async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let timer = Task {
                try await wait(timeout)
                guard once.claim() else { return }
                continuation.resume(throwing: PingTimeout())
            }
            Task {
                do {
                    try await connection.ping()
                    guard once.claim() else { return }
                    timer.cancel()
                    continuation.resume()
                } catch {
                    guard once.claim() else { return }
                    timer.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// 受信とpingの2つの経路から、成立とイベントを順序を保って積む。
/// 成立はイベントより先に、1回だけ積む。
private final class ActivityQueue: Sendable {
    private let state: Mutex<(continuation: AsyncThrowingStream<ReconnectingStream.Activity, any Error>.Continuation, isConnected: Bool)>

    init(_ continuation: AsyncThrowingStream<ReconnectingStream.Activity, any Error>.Continuation) {
        state = Mutex((continuation, false))
    }

    func connected() {
        state.withLock { state in
            guard !state.isConnected else { return }
            state.isConnected = true
            state.continuation.yield(.connected)
        }
    }

    func event(_ event: StreamingMessage) {
        state.withLock { state in
            if !state.isConnected {
                state.isConnected = true
                state.continuation.yield(.connected)
            }
            state.continuation.yield(.event(event))
        }
    }

    func finish(throwing error: any Error) {
        state.withLock { $0.continuation.finish(throwing: error) }
    }
}

/// 複数の経路のうち、最初の1つだけが続きを行うための印。
private final class OnceFlag: Sendable {
    private let isClaimed = Mutex(false)

    /// 最初の呼び出しだけtrueを返す。
    func claim() -> Bool {
        isClaimed.withLock { isClaimed in
            defer { isClaimed = true }
            return !isClaimed
        }
    }
}
