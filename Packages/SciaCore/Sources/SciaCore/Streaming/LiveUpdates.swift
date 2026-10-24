import Foundation

/// ストリーミングの接続を保ち、つながっていない間はポーリングを促す。つながらない状態が続いたら知らせる。
///
/// ストリーミングに対応していないサーバーや、接続先を調べられないサーバーでも、ポーリングで新着が届くようにする。
/// つなぎ直しは`ReconnectingStream`が続けるため、ポーリングの間につながれば、そこでポーリングをやめる。
public struct LiveUpdates: Sendable {
    public enum Activity: Sendable, Equatable {
        case stream(ReconnectingStream.Activity)
        /// つながっていない間、`pollingInterval`ごとに届く。切れていた間の新着をRESTで読む。
        case poll
        /// つながらない状態が`outageNoticeDelay`続いた（true）、またはその後につながった（false）。
        case outage(isOngoing: Bool)
    }

    public struct Policy: Sendable {
        public var pollingInterval: Duration
        /// 短い切断のたびに知らせないよう、これだけ続いてから知らせる。
        public var outageNoticeDelay: Duration

        public init(pollingInterval: Duration, outageNoticeDelay: Duration) {
            self.pollingInterval = pollingInterval
            self.outageNoticeDelay = outageNoticeDelay
        }
    }

    private let stream: ReconnectingStream
    private let policy: Policy
    private let clock: any Clock<Duration>

    /// - Parameter clock: ポーリングと知らせまでの時間を数える。テストでは手で進める時計を渡す。
    public init(stream: ReconnectingStream, policy: Policy, clock: any Clock<Duration> = SystemTime.clock) {
        self.stream = stream
        self.policy = policy
        self.clock = clock
    }

    /// 内側の出来事。タイマーは切れるたびに数える世代を持ち、つながった後に届いた古いタイマーを捨てる。
    private enum Signal: Sendable {
        case stream(ReconnectingStream.Activity)
        case pollDue(outage: Int)
        case noticeDue(outage: Int)
    }

    /// キャンセルされるまで続ける。`handle`は届いた順に1つずつ呼ぶ。
    public func run(_ handle: @escaping @Sendable (Activity) async -> Void) async throws {
        let (signals, continuation) = AsyncStream<Signal>.makeStream()
        let stream = stream
        let policy = policy
        let clock = clock
        let streaming = Task {
            defer { continuation.finish() }
            try await stream.run { continuation.yield(.stream($0)) }
        }
        var outage = 0
        var isOutage = false
        var isNoticed = false
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }

        func beginOutage() {
            guard !isOutage else { return }
            isOutage = true
            isNoticed = false
            outage += 1
            let current = outage
            timer = Task {
                await withDiscardingTaskGroup { group in
                    group.addTask {
                        guard (try? await clock.sleep(for: policy.outageNoticeDelay)) != nil else { return }
                        continuation.yield(.noticeDue(outage: current))
                    }
                    group.addTask {
                        while (try? await clock.sleep(for: policy.pollingInterval)) != nil {
                            continuation.yield(.pollDue(outage: current))
                        }
                    }
                }
            }
        }

        await withTaskCancellationHandler {
            // つながるまでは、切れているものとして数え始める。
            beginOutage()
            for await signal in signals {
                // 止めた後に、たまっていたポーリングや知らせを流さない。止めた側は表示を消しているため、出し直してしまう。
                if Task.isCancelled { break }
                switch signal {
                case .stream(let activity):
                    await handle(.stream(activity))
                    switch activity {
                    case .connected:
                        timer?.cancel()
                        timer = nil
                        isOutage = false
                        if isNoticed {
                            isNoticed = false
                            await handle(.outage(isOngoing: false))
                        }
                    case .disconnected:
                        beginOutage()
                    case .event, .unauthorized:
                        break
                    }
                case .pollDue(let due):
                    guard isOutage, due == outage else { continue }
                    await handle(.poll)
                case .noticeDue(let due):
                    guard isOutage, due == outage, !isNoticed else { continue }
                    isNoticed = true
                    await handle(.outage(isOngoing: true))
                }
            }
        } onCancel: {
            streaming.cancel()
        }
        try await streaming.value
    }
}
