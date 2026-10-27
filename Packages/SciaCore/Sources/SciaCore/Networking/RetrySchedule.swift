public import Foundation

/// 読めなかったもの（画像、Xの投稿、動画の最初のコマ）を覚え、行を描いたときのような自動の読み込みで、いつ読み直してよいかを決める。
/// 待てば直る失敗（通信の失敗、408、429、5xx）は、失敗するたびに間隔を倍にして上限で止め、応答が再開の時刻を示していればそれまで待つ。
/// 待っても直らない失敗（そのほかの4xx、読めない中身）は、自動では読み直さない。分け方は`HTTPFailure`に従う。
/// 使う人が自分で見に行った操作（ビューアを開くなど）は、これに聞かずに読む。読めたら`recordSuccess`で忘れる。
@MainActor
public struct RetrySchedule {
    public struct Policy: Sendable {
        /// 1回目の失敗のあとに待つ長さ。続けて失敗するたびに倍にする。
        public var initialDelay: Duration
        public var maxDelay: Duration
        public var jitter: Jitter

        public init(initialDelay: Duration, maxDelay: Duration, jitter: Jitter = .none) {
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
            self.jitter = jitter
        }

        func delay(afterFailures failures: Int, retryAfter: Duration?) -> Duration {
            Backoff(initial: initialDelay, maximum: maxDelay, jitter: jitter).delay(afterFailures: failures, retryAfter: retryAfter)
        }
    }

    private enum Record {
        case temporary(failures: Int, retryAt: Duration)
        case permanent
    }

    private let policy: @MainActor () -> Policy
    private let elapsed: @Sendable () -> Duration
    private var records: [URL: Record] = [:]
    /// 制限の単位（`rateLimitScope`）ごとの、読み直してよくなる時刻。
    private var pausedScopes: [String: Duration] = [:]

    /// - Parameter policy: 失敗したときに読む。チューニングで変えた間隔を、次の失敗から効かせる。
    public init(policy: @escaping @MainActor () -> Policy, clock: any Clock<Duration>) {
        self.policy = policy
        elapsed = stopwatch(on: clock)
    }

    /// 自動で読んでよいか。読めなかったことがなければtrue。
    public func allowsAutomaticLoad(of url: URL) -> Bool {
        let now = elapsed()
        if let scope = Self.rateLimitScope(of: url), let until = pausedScopes[scope], now < until {
            return false
        }
        switch records[url] {
        case nil: return true
        case .permanent: return false
        case .temporary(_, let retryAt): return now >= retryAt
        }
    }

    /// 読めなかったことがあるか。待てば直るものも含める。先読みのように、読めない画像のために通信を増やしたくないところで使う。
    public func hasFailed(_ url: URL) -> Bool {
        records[url] != nil
    }

    /// 読めなかったことを覚える。取り消しは失敗ではないので覚えない。
    public mutating func recordFailure(_ error: any Error, for url: URL) {
        switch HTTPFailure(error) {
        // 回線で控えたものは、回線が変わって描き直したときに読むものを選び直すので、時間では覚えない。
        case nil, .unavailableOnNetwork:
            return
        case .permanent, .unauthorized:
            records[url] = .permanent
        case .temporary(let retryAfter):
            let now = elapsed()
            let failures: Int
            if case .temporary(let previous, _)? = records[url] {
                failures = previous + 1
            } else {
                failures = 1
            }
            records[url] = .temporary(failures: failures, retryAt: now + policy().delay(afterFailures: failures, retryAfter: retryAfter))
            if let retryAfter, let scope = Self.rateLimitScope(of: url) {
                pausedScopes[scope] = max(pausedScopes[scope] ?? .zero, now + retryAfter)
            }
        }
    }

    public mutating func recordSuccess(for url: URL) {
        records[url] = nil
    }

    /// 応答の制限が掛かる単位。Mastodonは`/media_proxy`への読み込みをIPごとにまとめて制限するため（`config/initializers/rack_attack.rb`の`throttle_media_proxy`）、
    /// 1つが429を返したら、同じサーバーの`/media_proxy`をまとめて止める。止めないと、ほかの画像もそれぞれ429を受けに行く。
    /// サーバーが保存し直した画像のように、制限の掛からないURLはnilで、そのURLだけを止める。
    static func rateLimitScope(of url: URL) -> String? {
        guard let host = url.host(), isMediaProxy(url) else { return nil }
        return "\(host)/media_proxy"
    }

    /// Mastodonが、ほかのサーバーの画像を中継するURL。
    nonisolated static func isMediaProxy(_ url: URL) -> Bool {
        url.path().hasPrefix("/media_proxy/")
    }
}

/// 前に読めなかった画像の自動の読み込みを、読み直してよくなるまで見送った。
public struct ImageLoadDeferred: Error, Equatable, Sendable {
    public init() {}
}
