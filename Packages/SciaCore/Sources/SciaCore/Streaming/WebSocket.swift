public import Foundation

/// WebSocketの接続を開く口。テストではstubに差し替える。
public protocol WebSocketConnector: Sendable {
    /// ハンドシェイクを待たずに接続を返す。ハンドシェイクの失敗は最初の`receive()`で投げられる。
    func connect(_ request: URLRequest) -> any WebSocketConnection
}

public protocol WebSocketConnection: Sendable {
    /// 次のテキストメッセージを待つ。接続が切れたら投げる。
    func receive() async throws -> String
    /// テキストメッセージを送る。ハンドシェイクが済んでいなければ、済むのを待ってから送る。
    func send(_ text: String) async throws
    /// 応答が返るまで待つ。ハンドシェイクが済んでいなければ、済むのを待ってから送る。
    func ping() async throws
    /// 待っている`receive()`と`ping()`は投げて終わる。
    func close()
}

/// WebSocketのハンドシェイクが、101以外のHTTPの応答で断られた。再開の時刻を読めるよう、ステータスとヘッダーを持つ。
public struct WebSocketHandshakeRejected: Error, Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }

    init(response: HTTPURLResponse) {
        statusCode = response.statusCode
        headers = Dictionary(
            response.allHeaderFields.compactMap { key, value in (key as? String).map { ($0, "\(value)") } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// ヘッダーの名前は大文字と小文字を区別しない。
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
