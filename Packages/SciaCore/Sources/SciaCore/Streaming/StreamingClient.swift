public import Foundation
import os

/// ストリーミングAPIへWebSocketで接続する。購読するタイムラインは、つないだ後に`StreamingConnection.subscribe(_:)`で選ぶ。
/// https://docs.joinmastodon.org/methods/streaming/#websocket
public struct StreamingClient: Sendable {
    public let credential: Credential
    private let connector: any WebSocketConnector

    public init(credential: Credential, connector: any WebSocketConnector) {
        self.credential = credential
        self.connector = connector
    }

    /// - Parameter baseURL: `StreamingEndpoint.url()`で得た接続先。
    public func open(baseURL: URL) -> StreamingConnection {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/streaming"))
        // クエリのaccess_tokenはアクセスログに残りうるため、推奨されているヘッダーで渡す。
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        return StreamingConnection(connection: connector.connect(request))
    }
}

/// 1本の接続で購読するタイムライン。
/// https://docs.joinmastodon.org/methods/streaming/#streams
public struct StreamingSubscription: Sendable, Hashable {
    /// ホームタイムラインと通知。
    public static let user = StreamingSubscription(stream: "user")

    /// リストのタイムライン。
    public static func list(_ id: String) -> StreamingSubscription {
        StreamingSubscription(stream: "list", list: id)
    }

    /// `subscribe`で送るストリームの名前。
    public let stream: String
    /// `list`ストリームで購読するリストのID。
    public let list: String?

    public init(stream: String, list: String? = nil) {
        self.stream = stream
        self.list = list
    }

    /// 届いたイベントの`stream`欄。リストなら`["list", "<id>"]`のように引数が続く。
    var streamPath: [String] { [stream] + (list.map { [$0] } ?? []) }

    func message(_ type: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var fields = ["type": type, "stream": stream]
        fields["list"] = list
        return String(decoding: try encoder.encode(fields), as: UTF8.self)
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
    public func next() async throws -> StreamingMessage {
        while true {
            let text = try await connection.receive()
            do {
                return try StreamingMessageDecoder.decode(text)
            } catch let error as StreamingServerError {
                throw error
            } catch {
                logger.error("streaming decode failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 購読を始める。受け付けたかの応答はなく、失敗したときだけエラーのメッセージが届く。
    public func subscribe(_ subscription: StreamingSubscription) async throws {
        try await connection.send(try subscription.message("subscribe"))
    }

    public func unsubscribe(_ subscription: StreamingSubscription) async throws {
        try await connection.send(try subscription.message("unsubscribe"))
    }

    /// 応答が返るまで待つ。接続が生きているかを確かめるのに使う。
    public func ping() async throws {
        try await connection.ping()
    }

    public func close() {
        connection.close()
    }
}
