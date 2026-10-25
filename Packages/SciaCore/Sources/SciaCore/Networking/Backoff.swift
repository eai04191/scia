/// 失敗が続くたびに、次に試すまでの長さを倍にし、上限で止める。送り直し、つなぎ直し、読み直しのどれも、この決まりで間隔を決める。
public struct Backoff: Sendable {
    /// 1回目の失敗のあとに待つ長さ。
    public var initial: Duration
    /// これより長くはしない。nilなら倍にし続ける。
    public var maximum: Duration?
    public var jitter: Jitter

    public init(initial: Duration, maximum: Duration?, jitter: Jitter = .none) {
        self.initial = initial
        self.maximum = maximum
        self.jitter = jitter
    }

    /// - Parameter failures: 続けて失敗した回数。1から数える。
    public func delay(afterFailures failures: Int) -> Duration {
        var delay = initial
        for _ in 1..<max(failures, 1) {
            if let maximum, delay >= maximum { break }
            delay *= 2
        }
        if let maximum {
            delay = min(delay, maximum)
        }
        return jitter.apply(to: delay)
    }

    /// 自分の間隔と、応答が示した再開までの長さの遅いほう。再開の時刻より前には試さない。
    /// 再開までの長さには揺らぎを足さない。サーバーが決めた時刻より早めることになるため。
    public func delay(afterFailures failures: Int, retryAfter: Duration?) -> Duration {
        max(delay(afterFailures: failures), retryAfter ?? .zero)
    }
}

/// 待つ長さに、乱数で幅を持たせる。サーバーが戻った直後に、つなぎ直しや読み直しが同じ時刻に重ならないようにする。
public struct Jitter: Sendable {
    /// 長さを、1からこの割合だけ上下に散らす。0.2なら0.8倍から1.2倍。
    public var spread: Double
    /// 0以上1未満の乱数。テストでは決まった値に差し替える。
    public var random: @Sendable () -> Double

    public init(spread: Double, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.spread = spread
        self.random = random
    }

    /// 散らさない。テストで間隔をそのまま確かめるときに使う。
    public static let none = Jitter(spread: 0) { 0.5 }
    /// 送り直し、つなぎ直し、読み直しの既定。2割ずつ散らせば、同じ間隔で失敗した処理どうしが、次も同じ時刻に重なることはまずない。
    public static let standard = Jitter(spread: 0.2)

    func apply(to delay: Duration) -> Duration {
        guard spread > 0 else { return delay }
        return delay * (1 - spread + 2 * spread * random())
    }
}
