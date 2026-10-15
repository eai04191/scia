public import Foundation
import os

/// ストリーミングAPIの接続先を調べ、セッションの間は覚えておく。ホームと通知の接続で共有する。
///
/// v2の`instance`から読めなければ、v1の`urls.streaming_api`を使う。どちらも読めなければ投げ、覚えずに次の呼び出しで調べ直す。
public actor StreamingEndpoint {
    private let client: MastodonClient
    private var resolved: URL?
    /// 同時に呼ばれても、調べる通信を1回にまとめる。
    private var resolving: Task<URL, any Error>?
    private let logger = SciaLog.logger(category: "streaming")

    public init(client: MastodonClient) {
        self.client = client
    }

    public func url() async throws -> URL {
        if let resolved { return resolved }
        let task = resolving ?? Task { [client, logger] in
            do {
                return try await client.streamingURLFromV2()
            } catch {
                logger.info("streaming endpoint v2 failed, trying v1 error=\(String(describing: error), privacy: .public)")
                return try await client.streamingURLFromV1()
            }
        }
        resolving = task
        defer {
            // 待っている間に失敗して、別の呼び出しが調べ直し始めていれば、そちらは残す。
            if resolving == task { resolving = nil }
        }
        let url = try await task.value
        resolved = url
        return url
    }
}
