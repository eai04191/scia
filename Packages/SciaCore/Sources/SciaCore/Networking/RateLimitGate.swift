public import Foundation

/// 429や503でサーバーに止められたとき、再開の時刻まで自動の通信を控える。セッションの中で共有する。
///
/// 再開の時刻は`Retry-After`か`X-RateLimit-Reset`から読む。どちらもなければ止めない。いつまで止めればよいか分からないため。
/// 再開の時刻になったら`resumptions`で知らせ、失敗していた読み込みをやり直せるようにする。
public actor RateLimitGate {
    /// 自動の通信を控えている間の、再開の時刻。
    public private(set) var pausedUntil: Date?
    /// 止めていた時刻が過ぎるたびに流れる。受け取るのは1か所だけ。
    public nonisolated let resumptions: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>
    private var timer: Task<Void, Never>?

    /// `now`は今の時刻を返し、`clock`で再開の時刻まで待つ。テストでは手で進める時計を渡す。
    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        (resumptions, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.now = now
        self.clock = clock
    }

    deinit {
        timer?.cancel()
        continuation.finish()
    }

    /// `date`まで自動の通信を控える。もっと先まで控えていれば、そのままにする。
    public func pause(until date: Date) {
        if let pausedUntil, pausedUntil >= date { return }
        pausedUntil = date
        timer?.cancel()
        let delay = max(date.timeIntervalSince(now()), 0)
        let clock = clock
        timer = Task { [weak self] in
            guard (try? await clock.sleep(for: .seconds(delay))) != nil else { return }
            await self?.resume(pausedUntil: date)
        }
    }

    /// 429や503の応答から再開の時刻を読み、そこまで控える。時刻が分からないか、もう過ぎていれば止めず、falseを返す。
    /// 過ぎた時刻で止めると、すぐに再開を知らせ、読み込み直しが同じ応答を受けて繰り返すため。
    @discardableResult
    func pause(respondingTo response: HTTPURLResponse) -> Bool {
        let now = now()
        guard let date = Self.resumeDate(of: response, now: now), date > now else { return false }
        pause(until: date)
        return true
    }

    /// 自動の通信を送ってよいか確かめる。控えている間なら投げる。
    func checkAutomaticRequest() throws(AutomaticRequestsPaused) {
        guard let pausedUntil, now() < pausedUntil else { return }
        throw AutomaticRequestsPaused(until: pausedUntil)
    }

    private func resume(pausedUntil date: Date) {
        guard pausedUntil == date else { return }
        pausedUntil = nil
        continuation.yield()
    }

    /// 応答のヘッダーから再開の時刻を読む。`Retry-After`を優先する。
    /// https://www.rfc-editor.org/rfc/rfc9110.html#name-retry-after
    /// https://docs.joinmastodon.org/api/rate-limits/
    static func resumeDate(of response: HTTPURLResponse, now: Date) -> Date? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Int(retryAfter), seconds >= 0 {
                return now.addingTimeInterval(TimeInterval(seconds))
            }
            if let date = httpDate(retryAfter) {
                return date
            }
        }
        if let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset") {
            return (try? Date(reset, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
                ?? (try? Date(reset, strategy: .iso8601))
        }
        return nil
    }

    private static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}

/// レート制限で止められている間に、自動の通信を送ろうとした。
public struct AutomaticRequestsPaused: Error, Equatable {
    /// 再開の時刻。
    public let until: Date

    public init(until: Date) {
        self.until = until
    }
}
