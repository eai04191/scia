import Foundation


/// 一時的な失敗で、自動で送り直す回数と間隔。
///
/// 送り直すのは、何度送っても結果が変わらないGETと、`Idempotency-Key`付きの投稿だけ。
/// お気に入りなどは、サーバーに届いていたかどうか分からないまま送り直すと、意図しない結果になりうるため送り直さない。
public struct RetryPolicy: Sendable {
    public var maxRetries: Int
    /// 1回目の送り直しの前に待つ時間。送り直すたびに倍にする。
    public var initialDelay: Duration
    public var jitter: Jitter

    public init(maxRetries: Int, initialDelay: Duration, jitter: Jitter = .none) {
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.jitter = jitter
    }

    public static let standard = RetryPolicy(maxRetries: 2, initialDelay: .seconds(1), jitter: .standard)

    /// - Parameter retry: 何回目の送り直しか。1から数える。
    func delay(beforeRetry retry: Int) -> Duration {
        Backoff(initial: initialDelay, maximum: nil, jitter: jitter).delay(afterFailures: retry)
    }

    static func canRetry(_ request: URLRequest) -> Bool {
        let method = request.httpMethod ?? "GET"
        return method == "GET" || request.value(forHTTPHeaderField: "Idempotency-Key") != nil
    }

    /// 少し待てば通りうる失敗。再開の時刻を示した429や503は、送り直さずに自動の通信を止める側で扱う。
    static func isTemporary(statusCode: Int) -> Bool {
        [502, 503, 504].contains(statusCode)
    }

    static func isTemporary(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}
