public import Foundation

/// 絵文字、アイコン、添付ファイルなどの画像を、APIの外のURLから取得する。
/// 2xx以外の応答は、本文（エラーのHTMLのページなど）を画像として渡さずに`RemoteFetchError`で失敗させる。
/// 渡すと、一時的な503でも、画像として読めない壊れたデータとして扱われてしまうため。
public struct RemoteFetch: Sendable {
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    /// - Parameter now: 応答の`X-RateLimit-Reset`のような再開の時刻を、待つ長さに直すための今の日付。
    public init(transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = SystemTime.now) {
        self.transport = transport
        self.now = now
    }

    public func data(from url: URL) async throws -> Data {
        // デバッグのダミー投稿と部品カタログは、画像を`data:`のURLで渡す。HTTPの応答がなく、確かめるステータスもないので、そのまま読む。
        guard url.scheme == "http" || url.scheme == "https" else {
            return try Data(contentsOf: url)
        }
        let (data, response) = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteFetchError(response: response, now: now())
        }
        return data
    }
}

/// 外のURLが2xx以外を返した。
public struct RemoteFetchError: Error, Equatable, Sendable {
    public let statusCode: Int
    /// 応答が示した、読み直してよくなるまでの長さ。`Retry-After`か`X-RateLimit-Reset`から読む。なければnil。
    /// Mastodonは`/media_proxy`を制限したときの429に、`X-RateLimit-Reset`だけを付ける。
    public let retryAfter: Duration?

    public init(statusCode: Int, retryAfter: Duration? = nil) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }

    init(response: HTTPURLResponse, now: Date) {
        statusCode = response.statusCode
        retryAfter = RateLimitGate.resumeDate(of: response, now: now).map { .seconds(max($0.timeIntervalSince(now), 0)) }
    }
}
