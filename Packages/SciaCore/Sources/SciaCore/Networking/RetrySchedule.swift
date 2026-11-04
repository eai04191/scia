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
        /// 描いている画像が隠れている間に、見えるようになったかを確かめる間隔。見えたら、読み直してよければすぐ読む。
        public var hiddenRecheckInterval: Duration

        public init(initialDelay: Duration, maxDelay: Duration, jitter: Jitter = .none, hiddenRecheckInterval: Duration = .seconds(1)) {
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
            self.jitter = jitter
            self.hiddenRecheckInterval = hiddenRecheckInterval
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

    /// 自動で読んでよくなるまでの長さ。今読んでよければ0、待っても直らない失敗ならnil。
    public func delayUntilAutomaticLoad(of url: URL) -> Duration? {
        let now = elapsed()
        var until = now
        if let scope = Self.rateLimitScope(of: url), let paused = pausedScopes[scope] {
            until = max(until, paused)
        }
        switch records[url] {
        case nil: break
        case .permanent: return nil
        case .temporary(_, let retryAt): until = max(until, retryAt)
        }
        return until - now
    }

    /// 描いている画像が隠れている間に、見えるようになったかを確かめる間隔。
    public var hiddenRecheckInterval: Duration {
        policy().hiddenRecheckInterval
    }

    /// 画面に描いている間、待てば直る失敗を、読み直してよくなった時刻に読み直す（docs/image-loading.md）。
    /// 行を描き直したときだけ読み直すと、画面に出たままの行は、間隔が過ぎても、レート制限が明けても、読めないまま残るため。
    /// 最初の1回は、見えているかによらず読む。読み直しは見えている間だけにし、隠れている間（ほかのタブ、折りたたんだ注意書きの下、使い回しを待つセルなど）は、
    /// `recheck`ごとに見えたかを確かめる。隠れたまま読み直すと、見ている画像と同じ`/media_proxy`の制限を使ってしまうため。
    /// 待っても直らない失敗、覚えない失敗（回線で控えたものなど）、取り消し、`isWanted`がfalseになったら、nilを返してやめる。
    /// - Parameter isWanted: まだその画像を描こうとしているか。描く画像が替わったり、ビューがなくなったりしたらfalse。
    /// - Parameter delay: 読めなかったあとに、読み直してよくなるまでの長さ（`delayUntilAutomaticLoad(of:)`）。
    static func loadWhileShown<Value>(
        clock: any Clock<Duration>,
        isWanted: @MainActor () -> Bool,
        isVisible: @MainActor () -> Bool,
        recheck: @MainActor () -> Duration,
        delay: @MainActor () -> Duration?,
        load: @MainActor () async throws -> Value
    ) async -> Value? {
        var hasLoaded = false
        while !Task.isCancelled, isWanted() {
            if hasLoaded, !isVisible() {
                guard (try? await clock.sleep(for: recheck())) != nil else { return nil }
                continue
            }
            hasLoaded = true
            if let value = try? await load() {
                return value
            }
            // 覚えない失敗は今すぐ読んでよいことになるので、ここで続けると読み直し続けてしまう。
            guard let wait = delay(), wait > .zero, (try? await clock.sleep(for: wait)) != nil else { return nil }
        }
        return nil
    }

    /// 読み直してよくなるまで待つ（`delayUntilAutomaticLoad(of:)`）。待つ間に失敗を重ねたり制限が延びたりしたら、その時刻まで待ち直す。
    /// 画面を描き直して読み直させるストア（絵文字、Xの投稿）が、読み直してよくなったことを知らせるのに使う。
    /// - Returns: 読み直してよくなったらtrue。待っても直らない失敗になったか、取り消されたらfalse。
    static func waitUntilAutomaticLoad(clock: any Clock<Duration>, delay: @MainActor () -> Duration?) async -> Bool {
        while let wait = delay() {
            guard wait > .zero else { return true }
            guard (try? await clock.sleep(for: wait)) != nil else { return false }
        }
        return false
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
