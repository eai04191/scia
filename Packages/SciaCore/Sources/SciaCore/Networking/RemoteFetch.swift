public import Foundation

/// 絵文字、アイコン、添付ファイルなどの画像を、APIの外のURLから取得する。
/// 2xx以外の応答は、本文（エラーのHTMLのページなど）を画像として渡さずに`HTTPStatusError`で失敗させる。
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
            throw HTTPStatusError(response: response, now: now())
        }
        return data
    }
}
