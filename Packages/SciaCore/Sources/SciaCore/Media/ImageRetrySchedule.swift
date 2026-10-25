public import Foundation

/// 読めなかった画像を覚え、行を描いたときのような自動の読み込みで、いつ読み直してよいかを決める。
/// 待てば直る失敗（通信の失敗、408、429、5xx）は、失敗するたびに間隔を倍にして上限で止め、応答が再開の時刻を示していればそれまで待つ。
/// 待っても直らない失敗（そのほかの4xx、画像として読めないデータ）は、自動では読み直さない。
/// 使う人が自分で見に行った操作（ビューアを開くなど）は、これに聞かずに読む。読めたら`recordSuccess`で忘れる。
@MainActor
public struct ImageRetrySchedule {
    public struct Policy: Sendable {
        /// 1回目の失敗のあとに待つ長さ。続けて失敗するたびに倍にする。
        public var initialDelay: Duration
        public var maxDelay: Duration

        public init(initialDelay: Duration, maxDelay: Duration) {
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
        }

        func delay(afterFailures failures: Int) -> Duration {
            var delay = initialDelay
            for _ in 1..<max(failures, 1) where delay < maxDelay {
                delay *= 2
            }
            return min(delay, maxDelay)
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
        switch Failure(error) {
        case nil:
            return
        case .permanent:
            records[url] = .permanent
        case .temporary(let retryAfter):
            let now = elapsed()
            let failures: Int
            if case .temporary(let previous, _)? = records[url] {
                failures = previous + 1
            } else {
                failures = 1
            }
            let backoff = policy().delay(afterFailures: failures)
            records[url] = .temporary(failures: failures, retryAt: now + max(backoff, retryAfter ?? .zero))
            if let retryAfter, let scope = Self.rateLimitScope(of: url) {
                pausedScopes[scope] = max(pausedScopes[scope] ?? .zero, now + retryAfter)
            }
        }
    }

    public mutating func recordSuccess(for url: URL) {
        records[url] = nil
    }

    enum Failure: Equatable {
        case temporary(retryAfter: Duration?)
        case permanent

        /// 取り消しはnil。
        init?(_ error: any Error) {
            if error is CancellationError { return nil }
            if let error = error as? URLError {
                // 通信の失敗は、つながれば読める。
                guard error.code != .cancelled else { return nil }
                self = .temporary(retryAfter: nil)
                return
            }
            if let error = error as? RemoteFetchError {
                switch error.statusCode {
                case 408, 429, 500...599: self = .temporary(retryAfter: error.retryAfter)
                default: self = .permanent
                }
                return
            }
            // 画像として読めないデータなど。
            self = .permanent
        }
    }

    /// 応答の制限が掛かる単位。Mastodonは`/media_proxy`への読み込みをIPごとにまとめて制限するため（`config/initializers/rack_attack.rb`の`throttle_media_proxy`）、
    /// 1つが429を返したら、同じサーバーの`/media_proxy`をまとめて止める。止めないと、ほかの画像もそれぞれ429を受けに行く。
    /// サーバーが保存し直した画像のように、制限の掛からないURLはnilで、そのURLだけを止める。
    static func rateLimitScope(of url: URL) -> String? {
        guard let host = url.host(), url.path().hasPrefix("/media_proxy/") else { return nil }
        return "\(host)/media_proxy"
    }
}

/// 前に読めなかった画像の自動の読み込みを、読み直してよくなるまで見送った。
public struct ImageLoadDeferred: Error, Equatable, Sendable {
    public init() {}
}
