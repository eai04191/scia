public import Foundation

/// 絵文字、アイコン、添付ファイルなどの画像を、APIの外のURLから取得する。
/// 2xx以外の応答は、本文（エラーのHTMLのページなど）を画像として渡さずに`HTTPStatusError`で失敗させる。
/// 渡すと、一時的な503でも、画像として読めない壊れたデータとして扱われてしまうため。
/// 決まり（ホストごとに止める、送り直す、大きさの上限）は`HTTPClient`が守る。
public struct RemoteFetch: Sendable {
    private let client: HTTPClient

    public init(client: HTTPClient) {
        self.client = client
    }

    public func data(from url: URL) async throws -> Data {
        try await client.data(for: URLRequest(url: url), limit: ResponseLimit.image, scope: .host).0
    }
}
