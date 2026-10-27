public import Foundation
import os

/// ストリーミングAPIへWebSocketで接続する。購読するタイムラインは、つないだ後に`StreamingConnection.subscribe(_:)`で選ぶ。
/// https://docs.joinmastodon.org/methods/streaming/#websocket
///
/// REST APIと同じ決まりに従う（docs/network.md）。止められている間は、自動のつなぎ直しを送らない。
/// つなぐときに429や503で断られたら、示された再開の時刻まで、REST APIと同じ門でアカウントの自動の通信を止める。
public struct StreamingClient: Sendable {
    public let credential: Credential
    private let connector: any WebSocketConnector
    private let rateLimit: RateLimitGate
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - rateLimit: REST APIと共有する、アカウントの自動の通信を止める門。
    ///   - now: 断られた応答の再開の時刻を、待つ長さに直すための今の日付。
    public init(
        credential: Credential,
        connector: any WebSocketConnector,
        rateLimit: RateLimitGate = RateLimitGate(),
        now: @escaping @Sendable () -> Date = SystemTime.now
    ) {
        self.credential = credential
        self.connector = connector
        self.rateLimit = rateLimit
        self.now = now
    }

    /// - Parameter baseURL: `StreamingEndpoint.url()`で得た接続先。
    public func open(baseURL: URL) async throws -> StreamingConnection {
        if RequestPurpose.current.isAutomatic {
            try await rateLimit.checkAutomaticRequest()
        }
        var request = URLRequest(url: baseURL.appending(path: "api/v1/streaming"))
        // クエリのaccess_tokenはアクセスログに残りうるため、推奨されているヘッダーで渡す。
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        return StreamingConnection(connection: connector.connect(request), rateLimit: rateLimit, now: now)
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

    /// ハッシュタグのタイムライン。`name`は`#`を除いた名前。
    /// Mastodonのストリーミングサーバーは、`normalizeHashtag`でそろえた名前のチャンネルで購読をまとめ、イベントの`stream`欄には最初に送った名前を返す。
    /// 表記の違う同じタグ（フォローしている`scia`と本文の`#Scia`）を別に申し込むと、後のほうにはイベントが届かず、後のほうをやめるとサーバーでは両方の購読が外れる。
    /// そのため、サーバーと同じ決まりでそろえた名前で申し込み、同じタグの購読を1つにする。
    public static func hashtag(_ name: String) -> StreamingSubscription {
        StreamingSubscription(stream: "hashtag", tag: Hashtag.normalizedName(name))
    }

    /// `subscribe`で送るストリームの名前。
    public let stream: String
    /// `list`ストリームで購読するリストのID。
    public let list: String?
    /// `hashtag`ストリームで購読するハッシュタグの名前。
    public let tag: String?

    public init(stream: String, list: String? = nil, tag: String? = nil) {
        self.stream = stream
        self.list = list
        self.tag = tag
    }

    /// 届いたイベントの`stream`欄。リストなら`["list", "<id>"]`、ハッシュタグなら`["hashtag", "<名前>"]`のように、送った引数が続く。
    /// Mastodonのストリーミングサーバーは、`streamNameFromChannelName`で、送られた引数をそのまま返す。
    var streamPath: [String] { [stream] + [list, tag].compactMap(\.self) }

    func message(_ type: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var fields = ["type": type, "stream": stream]
        fields["list"] = list
        fields["tag"] = tag
        return String(decoding: try encoder.encode(fields), as: UTF8.self)
    }
}

/// 開いたストリーミング接続。
public struct StreamingConnection: Sendable {
    private let connection: any WebSocketConnection
    private let rateLimit: RateLimitGate
    private let now: @Sendable () -> Date
    private let logger = SciaLog.logger(category: "streaming")

    init(connection: any WebSocketConnection, rateLimit: RateLimitGate, now: @escaping @Sendable () -> Date) {
        self.connection = connection
        self.rateLimit = rateLimit
        self.now = now
    }

    /// ハンドシェイクを断られた失敗を、REST APIと同じエラーに直す。429や503が再開の時刻を示していれば、アカウントの自動の通信を止める。
    /// トークンが無効なときは401になり、ログインし直しを促せる。
    private func translating<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let rejection as WebSocketHandshakeRejected {
            let now = now()
            var retryAfter: Duration?
            if let date = RateLimitGate.resumeDate(header: rejection.header, now: now) {
                retryAfter = .seconds(max(date.timeIntervalSince(now), 0))
                if rejection.statusCode == 429 || rejection.statusCode == 503, date > now {
                    await rateLimit.pause(until: date)
                }
            }
            throw MastodonAPIError(
                statusCode: rejection.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: rejection.statusCode),
                retryAfter: retryAfter
            )
        }
    }

    /// 次のイベントを待つ。読めないイベントはログに残して読み飛ばす。接続が切れたら投げる。
    public func next() async throws -> StreamingMessage {
        while true {
            let text = try await translating { try await connection.receive() }
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
        let message = try subscription.message("subscribe")
        try await translating { try await connection.send(message) }
    }

    public func unsubscribe(_ subscription: StreamingSubscription) async throws {
        let message = try subscription.message("unsubscribe")
        try await translating { try await connection.send(message) }
    }

    /// 応答が返るまで待つ。接続が生きているかを確かめるのに使う。
    public func ping() async throws {
        try await translating { try await connection.ping() }
    }

    public func close() {
        connection.close()
    }
}
