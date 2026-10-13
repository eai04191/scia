public import Foundation
import os

/// ストリーミングAPIへWebSocketで接続する。
/// https://docs.joinmastodon.org/methods/streaming/#websocket
public struct StreamingClient: Sendable {
    /// 購読するタイムライン。
    public enum Stream: String, Sendable {
        /// ホームタイムラインと通知。
        case user
    }

    public let credential: Credential
    private let connector: any WebSocketConnector

    public init(credential: Credential, connector: any WebSocketConnector) {
        self.credential = credential
        self.connector = connector
    }

    /// - Parameter baseURL: `MastodonClient.streamingURL()`で得た接続先。
    public func open(_ stream: Stream, baseURL: URL) -> StreamingConnection {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/streaming").appending(queryItems: [
            URLQueryItem(name: "stream", value: stream.rawValue),
        ]))
        // クエリのaccess_tokenはアクセスログに残りうるため、推奨されているヘッダーで渡す。
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        return StreamingConnection(connection: connector.connect(request))
    }
}

/// 開いたストリーミング接続。
public struct StreamingConnection: Sendable {
    private let connection: any WebSocketConnection
    private let logger = SciaLog.logger(category: "streaming")

    init(connection: any WebSocketConnection) {
        self.connection = connection
    }

    /// 次のイベントを待つ。読めないイベントはログに残して読み飛ばす。接続が切れたら投げる。
    public func next() async throws -> StreamingEvent {
        while true {
            let text = try await connection.receive()
            do {
                return try StreamingMessageDecoder.decode(text)
            } catch let error as StreamingServerError {
                throw error
            } catch {
                logger.error("streaming decode failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public func close() {
        connection.close()
    }
}
