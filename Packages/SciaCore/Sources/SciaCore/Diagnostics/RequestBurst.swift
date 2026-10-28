public import Foundation
import Synchronization

/// 短い間に異常な数のリクエストを送ったことを見つける。
///
/// OSは、ログを出しすぎたプロセスのログを止める。リクエストを繰り返す不具合では、OSの通信部品が1回ごとにログを出すため、
/// 数分で止められ、違和感レポートもログを読めなくなる。OSのログはURLを伏せるので、何を繰り返したかも分からない。
/// そこで、送った数を自分で数え、多すぎたら何を送っていたかの内訳をerrorのログに1行で残す。
public struct RequestBurstCounter: Sendable {
    /// 数える長さ。
    public static let window: Duration = .seconds(1)
    /// `window`の間にこの数を送ったら、異常とみなす。
    /// ログを止められたMac版では、キャッシュに当たるリクエストを毎秒400〜700回送っていた。
    /// 一覧を速く流しても、画像は行ごとに数枚で、読んだものはメモリのキャッシュから出すため、その数分の1に収まる。
    public static let threshold = 200
    /// 一度残したら、続いている間もこの長さは残さない。続いた長さが、残した行の数で分かる。
    public static let cooldown: Duration = .seconds(10)

    private struct Sent: Sendable {
        let at: Duration
        let host: String
        let url: String
        let purpose: String
    }

    private var sent: [Sent] = []
    private var quietUntil: Duration?

    public init() {}

    /// 送ったリクエストを数える。異常な数に達したら、`window`の間に送ったものの内訳を返す。
    /// - Parameter at: 数え始めてからの時間。
    public mutating func record(url: URL?, purpose: RequestPurpose, at: Duration) -> RequestBurst? {
        sent.removeAll { at - $0.at >= Self.window }
        sent.append(Sent(at: at, host: SciaLog.host(of: url), url: url?.absoluteString ?? "", purpose: purpose.logName))
        guard sent.count >= Self.threshold, quietUntil.map({ at >= $0 }) ?? true else { return nil }
        quietUntil = at + Self.cooldown
        return RequestBurst(
            count: sent.count,
            hosts: Self.tally(sent.map(\.host)),
            purposes: Self.tally(sent.map(\.purpose)),
            distinctURLs: Set(sent.map(\.url)).count,
            topURL: Self.tally(sent.map(\.url)).first ?? RequestBurst.Tally(name: "", count: 0)
        )
    }

    /// 多い順に並べる。同じ数なら名前の順にして、並びを決める。
    private static func tally(_ names: [String]) -> [RequestBurst.Tally] {
        Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
            .map { RequestBurst.Tally(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }
}

/// `RequestBurstCounter.window`の間に送ったリクエストの内訳。
public struct RequestBurst: Sendable, Equatable {
    public struct Tally: Sendable, Equatable {
        public let name: String
        public let count: Int
    }

    public let count: Int
    public let hosts: [Tally]
    public let purposes: [Tally]
    /// 同じURLを繰り返したのか、違うURLを次々に送ったのかを分ける。
    public let distinctURLs: Int
    /// 一番多く送ったURL。ログには伏せて出す。
    public let topURL: Tally

    /// ホストと目的の内訳。ホストは多い順に5つまで。
    public var summary: String {
        let hosts = hosts.prefix(5).map { "\($0.name):\($0.count)" }.joined(separator: ",")
        let purposes = purposes.map { "\($0.name):\($0.count)" }.joined(separator: ",")
        return "count=\(count) hosts=\(hosts) purposes=\(purposes) distinctURLs=\(distinctURLs) topURLCount=\(topURL.count)"
    }
}

/// 通信の口を包み、送るリクエストを`RequestBurstCounter`で数える。
/// アプリのすべての通信を数えるため、APIの外の通信と、アカウントごとのAPIの通信の口で、同じ1つを共有する。
public final class RequestBurstMonitor: Sendable {
    private let counter = Mutex(RequestBurstCounter())
    private let elapsed: @Sendable () -> Duration
    private let onBurst: @Sendable (RequestBurst) -> Void

    /// - Parameter onBurst: 異常な数に達したときに、送った側の処理から呼ぶ。ログに残す。
    public init(clock: any Clock<Duration> = SystemTime.clock, onBurst: @escaping @Sendable (RequestBurst) -> Void) {
        elapsed = stopwatch(on: clock)
        self.onBurst = onBurst
    }

    func record(_ request: URLRequest) {
        let purpose = RequestPurpose.current
        let at = elapsed()
        guard let burst = counter.withLock({ $0.record(url: request.url, purpose: purpose, at: at) }) else { return }
        onBurst(burst)
    }
}

/// 送る前に`RequestBurstMonitor`で数えてから、包んだ口へ渡す。
public struct BurstMonitoringTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let monitor: RequestBurstMonitor

    public init(base: any HTTPTransport, monitor: RequestBurstMonitor) {
        self.base = base
        self.monitor = monitor
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        monitor.record(request)
        return try await base.send(request)
    }

    public func open(_ request: URLRequest, limit: Int) async throws -> (HTTPResponseBody, HTTPURLResponse) {
        monitor.record(request)
        return try await base.open(request, limit: limit)
    }

    public func download(_ request: URLRequest, limit: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        monitor.record(request)
        return try await base.download(request, limit: limit, progress: progress)
    }
}

extension RequestPurpose {
    /// ログに出す名前。
    public var logName: String {
        switch self {
        case .action: "action"
        case .display: "display"
        case .enhancement(let onExpensiveNetwork): onExpensiveNetwork ? "enhancement" : "enhancementWiFi"
        case .prefetch: "prefetch"
        }
    }
}
