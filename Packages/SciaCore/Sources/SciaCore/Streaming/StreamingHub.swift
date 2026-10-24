import Foundation
import os

/// ストリーミングの接続を1本だけ持ち、購読を申し込んだ相手へイベントと接続の状態を配る。
///
/// Mastodonは1本のWebSocketで複数のストリームを購読できるため、タイムラインごとに接続を増やさない。
/// 申し込みがある間だけつなぎ、なくなったら切る。つなぐたびに、申し込まれているストリームを購読し直す。
/// つながらない間のポーリングの合図も、ここから全員に配る。合図を受けて何をRESTで読むかは、受け取った側が決める。
/// https://docs.joinmastodon.org/methods/streaming/#websocket
@MainActor
public final class StreamingHub {
    /// 申し込んだ相手に届くもの。
    public enum Activity: Sendable, Equatable {
        /// 接続が成立した。申し込んだ時点でつながっていれば、すぐ届く。新しいストリームなら、購読を送り終えてから届く。切れていた間をRESTで補う。
        case connected
        /// 申し込んだストリームのイベント。
        case event(StreamingEvent)
        /// つながっていない間、ポーリングの間隔ごとに届く。切れていた間の新着をRESTで読む。
        case poll
        /// つながらない状態が続いた（true）、またはその後につながった（false）。申し込んだ時点で続いていれば、すぐ届く。
        case outage(isOngoing: Bool)
    }

    /// 申し込みをやめるときに`cancel()`する。やめた後は、何も届かない。
    @MainActor
    public final class Subscription {
        private weak var hub: StreamingHub?
        private let id: Int

        fileprivate init(hub: StreamingHub, id: Int) {
            self.hub = hub
            self.id = id
        }

        public func cancel() {
            hub?.remove(id)
            hub = nil
        }
    }

    private struct Consumer {
        let id: Int
        let subscription: StreamingSubscription
        let handler: (Activity) -> Void
    }

    public private(set) var state: ConnectionDiagnostics.StreamingState = .stopped
    /// 購読しているストリーム。最初に申し込まれた順。
    public private(set) var subscriptions: [StreamingSubscription] = []
    public private(set) var isConnected = false
    /// `state`か`subscriptions`が変わったときに呼ぶ。
    public var onChange: (() -> Void)?
    /// 接続が401で断られたときに呼ぶ。トークンが無効かは呼び出し側が確かめる。断られても、つなぎ直しは続ける。
    public var onUnauthorized: (() -> Void)?

    private let open: @Sendable () async throws -> StreamingConnection
    private let reconnectPolicy: ReconnectingStream.Policy
    private let livePolicy: () -> LiveUpdates.Policy
    private let clock: any Clock<Duration>
    private let logger = SciaLog.logger(category: "streaming")
    private var consumers: [Consumer] = []
    private var nextConsumerID = 0
    private var runTask: Task<Void, Never>?
    /// つなぎ始めるたびに増やす。止めた接続から遅れて届いた知らせを捨てる。
    private var generation = 0
    /// 今の接続。購読の変更を送る。切れたらnilにし、次の接続でまとめて購読し直す。
    private var connection: StreamingConnection?
    /// 接続を受け取るたびに増やす。同じ`generation`の中のつなぎ直しも見分け、前の接続で予約した知らせを捨てる。
    private var connectionNumber = 0
    /// 受け取った`connected`の数。ストリームの流れでは、どの接続でも`connected`がその接続のイベントより先に来るため、
    /// 届いたイベントがどの`connected`の後のものかを、これで見分ける。`connectionNumber`は次の接続を受け取った時点で進み、
    /// 前の接続のイベントを配り終える前のことがあるので、ここには使わない。
    private var connectedCount = 0
    /// 相手ごとに、届けた`connected`の`connectedCount`。
    private var reportedConnections: [Int: Int] = [:]
    /// `connected`を届ける前に届いたイベント。相手ごとに届いた順に溜め、`connected`の直後に渡す。
    /// 受け取った側は`connected`で補完を始めるので、先に新着を一覧に入れると補完の基準が進み、その手前を読み飛ばすため。
    /// 待っている間に切れても捨てず、つなぎ直した`connected`の後に渡す。削除や編集は、補完では読み直せないため。
    private var heldEvents: [Int: [StreamingEvent]] = [:]
    /// 購読と解除を、申し込みの順に1つずつ送る。テストで、積んだ送信が終わるまで待つ。
    private(set) var sending: Task<Void, Never>?
    /// 送り終えてから`connected`を届けるTaskの、最後に始めたもの。テストで、届けるか捨てるかが決まるまで待つ。
    private(set) var lastConnectedReportAfterSending: Task<Void, Never>?
    private var isOutageNoticed = false
    private var isLoginRequired = false
    /// 最後に`onChange`で知らせた購読。変わったときだけ知らせる。
    private var reportedSubscriptions: [StreamingSubscription] = []

    /// - Parameters:
    ///   - livePolicy: つなぎ始めるたびに読む。チューニングの値を、次の接続から効かせる。
    ///   - clock: つなぎ直し、ping、ポーリング、知らせまでの時間を数える。テストでは手で進める時計を渡す。
    ///   - open: 購読を指定せずに接続を開く。
    public init(
        reconnectPolicy: ReconnectingStream.Policy = .standard,
        livePolicy: @escaping () -> LiveUpdates.Policy,
        clock: any Clock<Duration> = SystemTime.clock,
        open: @escaping @Sendable () async throws -> StreamingConnection
    ) {
        self.reconnectPolicy = reconnectPolicy
        self.livePolicy = livePolicy
        self.clock = clock
        self.open = open
    }

    /// ストリームの購読を申し込む。最初の申し込みでつなぎ始める。同じストリームの申し込みは、1つの購読にまとめる。
    /// - Parameter handler: 届いた順に呼ぶ。つながっている間に申し込むと、すでに購読しているストリームなら返る前に、
    ///   新しいストリームなら購読を送り終えてから、`connected`で呼ぶ。
    public func subscribe(_ subscription: StreamingSubscription, _ handler: @escaping (Activity) -> Void) -> Subscription {
        nextConsumerID += 1
        let id = nextConsumerID
        consumers.append(Consumer(id: id, subscription: subscription, handler: handler))
        let isNewStream = !subscriptions.contains(subscription)
        if isNewStream {
            subscriptions.append(subscription)
            send { try await $0.subscribe(subscription) }
        }
        if runTask == nil {
            start()
        } else {
            if isConnected {
                if isNewStream {
                    // 受け取った側は`connected`で補完を始める。購読より先に補完が終わると、その間の新着をどちらでも受け取れない。
                    reportConnectedAfterSending(to: id)
                } else {
                    reportConnected(to: id, handler)
                }
            }
            if isOutageNoticed {
                handler(.outage(isOngoing: true))
            }
        }
        notifyChange()
        return Subscription(hub: self, id: id)
    }

    /// 電波が戻ったときなどに呼ぶ。つながっていなければ、つなぎ直しの待ち時間を飛ばして、すぐつなぎ直す。
    public func recover() {
        guard runTask != nil, !isConnected else { return }
        logger.info("streaming restart to recover")
        let wasNoticed = isOutageNoticed
        stop()
        // 切れている時間を数え直すので、知らせはいったん消す。
        if wasNoticed {
            broadcast(.outage(isOngoing: false))
        }
        start()
        notifyChange()
    }

    /// トークンが無効になったときに呼ぶ。切って、以後は申し込まれてもつながない。
    public func stopUntilLogin() {
        isLoginRequired = true
        stop()
        notifyChange()
    }

    private func remove(_ id: Int) {
        guard let index = consumers.firstIndex(where: { $0.id == id }) else { return }
        let subscription = consumers.remove(at: index).subscription
        reportedConnections[id] = nil
        heldEvents[id] = nil
        if !consumers.contains(where: { $0.subscription == subscription }) {
            subscriptions.removeAll { $0 == subscription }
            send { try await $0.unsubscribe(subscription) }
        }
        if consumers.isEmpty {
            stop()
        }
        notifyChange()
    }

    private func start() {
        guard !isLoginRequired, runTask == nil, !consumers.isEmpty else { return }
        generation += 1
        let generation = generation
        let open = open
        let stream = ReconnectingStream(policy: reconnectPolicy, clock: clock) { [weak self] in
            let connection = try await open()
            // 購読を送り終えてから返す。返した後のpingの応答で成立とみなし、補完を始めるため、
            // 先に返すと、補完の後から購読が効くまでの新着を取りこぼす。送れなければ、つながらなかったものとしてつなぎ直す。
            try await self?.attach(connection, generation: generation).value
            return connection
        }
        let updates = LiveUpdates(stream: stream, policy: livePolicy(), clock: clock)
        let logger = logger
        logger.info("streaming start")
        // 接続先を調べる通信も、自動の通信として扱う。
        runTask = RequestOrigin.$current.withValue(.automatic) {
            Task { [weak self] in
                do {
                    try await updates.run { [weak self] activity in
                        await self?.receive(activity, generation: generation)
                    }
                } catch is CancellationError {
                    // 止めたときだけ終わる。
                } catch {
                    logger.error("streaming ended error=\(SciaLog.describe(error), privacy: .public)")
                }
            }
        }
    }

    private func stop() {
        guard let runTask else { return }
        logger.info("streaming stop")
        runTask.cancel()
        self.runTask = nil
        connection = nil
        sending = nil
        reportedConnections.removeAll()
        isConnected = false
        isOutageNoticed = false
    }

    /// 開いた接続で、申し込まれているストリームをすべて購読する。返したTaskは、送り終えるか送れなかったら終わる。
    /// 送り終える前に申し込みが変わっても、その送信はこの後に続ける。
    private func attach(_ connection: StreamingConnection, generation: Int) -> Task<Void, any Error> {
        guard generation == self.generation, runTask != nil else { return Task {} }
        self.connection = connection
        connectionNumber += 1
        let subscriptions = subscriptions
        let initial = Task {
            for subscription in subscriptions {
                try await connection.subscribe(subscription)
            }
        }
        sending = Task { _ = await initial.result }
        return initial
    }

    /// 今の接続へ、前に送ったものの後に送る。つながっていなければ、次の接続で購読し直すので送らない。
    private func send(_ operation: @escaping @Sendable (StreamingConnection) async throws -> Void) {
        guard let connection else { return }
        let previous = sending
        let logger = logger
        sending = Task {
            await previous?.value
            do {
                try await operation(connection)
            } catch {
                // 送れないのは切れたときで、つなぎ直したときに購読し直す。
                logger.info("streaming send failed error=\(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 今までに積んだ送信が終わってから、まだ同じ接続で申し込んでいる相手に`connected`を届ける。
    /// その前に切れたら届けない。つなぎ直したときに、全員へ届くため。
    private func reportConnectedAfterSending(to id: Int) {
        let sent = sending
        let connectionNumber = connectionNumber
        lastConnectedReportAfterSending = Task { [weak self] in
            await sent?.value
            guard let self, connectionNumber == self.connectionNumber, isConnected, let consumer = consumers.first(where: { $0.id == id }) else { return }
            reportConnected(to: id, consumer.handler)
        }
    }

    /// `connected`を届け、それまでに溜めたイベントを続けて渡す。
    private func reportConnected(to id: Int, _ handler: (Activity) -> Void) {
        reportedConnections[id] = connectedCount
        handler(.connected)
        for event in heldEvents.removeValue(forKey: id) ?? [] where isSubscribed(id) {
            handler(.event(event))
        }
    }

    private func receive(_ activity: LiveUpdates.Activity, generation: Int) {
        guard generation == self.generation, runTask != nil else { return }
        switch activity {
        case .stream(.connected):
            isConnected = true
            connectedCount += 1
            logger.info("streaming connected")
            for consumer in consumers where isSubscribed(consumer.id) {
                reportConnected(to: consumer.id, consumer.handler)
            }
        case .stream(.event(let message)):
            deliver(message)
        case .stream(.unauthorized):
            logger.info("streaming unauthorized")
            onUnauthorized?()
        case .stream(.disconnected(let reason, let retryAfter)):
            isConnected = false
            connection = nil
            logger.info("streaming disconnected reason=\(reason, privacy: .public) retryAfter=\(retryAfter, privacy: .public)")
        case .poll:
            logger.info("streaming poll")
            broadcast(.poll)
        case .outage(let isOngoing):
            logger.info("streaming outage ongoing=\(isOngoing, privacy: .public)")
            isOutageNoticed = isOngoing
            broadcast(.outage(isOngoing: isOngoing))
        }
        notifyChange()
    }

    private func deliver(_ message: StreamingMessage) {
        let targets = consumers.filter { $0.subscription.streamPath == message.stream }
        guard !targets.isEmpty else {
            // 解除を送った後に、すでに送られていたイベントが届くことがある。
            logger.info("streaming event for unsubscribed stream=\(message.stream, privacy: .public)")
            return
        }
        for target in targets where isSubscribed(target.id) {
            if reportedConnections[target.id] == connectedCount {
                target.handler(.event(message.event))
            } else {
                heldEvents[target.id, default: []].append(message.event)
            }
        }
    }

    /// 配っている途中で申し込みをやめた相手には、残りを配らない。
    private func broadcast(_ activity: Activity) {
        for consumer in consumers where isSubscribed(consumer.id) {
            consumer.handler(activity)
        }
    }

    private func isSubscribed(_ id: Int) -> Bool {
        consumers.contains { $0.id == id }
    }

    private func notifyChange() {
        let newState: ConnectionDiagnostics.StreamingState =
            if isLoginRequired { .loginRequired }
            else if runTask == nil { .stopped }
            else if isConnected { .connected }
            // 切れていると知らせた後は、つなぎ直しに失敗するたびに戻さず、切断中のままにする。
            else if isOutageNoticed { .polling }
            else { .connecting }
        guard newState != state || subscriptions != reportedSubscriptions else { return }
        state = newState
        reportedSubscriptions = subscriptions
        onChange?()
    }
}
