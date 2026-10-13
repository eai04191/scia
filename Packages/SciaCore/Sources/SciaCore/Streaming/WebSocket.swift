public import Foundation

/// WebSocketの接続を開く口。テストではstubに差し替える。
public protocol WebSocketConnector: Sendable {
    /// ハンドシェイクを待たずに接続を返す。ハンドシェイクの失敗は最初の`receive()`で投げられる。
    func connect(_ request: URLRequest) -> any WebSocketConnection
}

public protocol WebSocketConnection: Sendable {
    /// 次のテキストメッセージを待つ。接続が切れたら投げる。
    func receive() async throws -> String
    func close()
}

public struct URLSessionWebSocketConnector: WebSocketConnector {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(_ request: URLRequest) -> any WebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

struct URLSessionWebSocketConnection: WebSocketConnection {
    let task: URLSessionWebSocketTask

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text):
                return text
            case .data(let data):
                // Mastodonはテキストフレームだけを送るが、念のためUTF-8として読む。
                return String(decoding: data, as: UTF8.self)
            @unknown default:
                throw URLError(.cannotParseResponse)
            }
        } catch {
            throw handshakeError() ?? error
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// ハンドシェイクがHTTPのエラーで断られていたら、REST APIと同じエラーとして返す。
    /// トークンが無効なときは401になり、ログインし直しを促せる。
    private func handshakeError() -> MastodonAPIError? {
        guard let response = task.response as? HTTPURLResponse, response.statusCode != 101 else { return nil }
        return MastodonAPIError(statusCode: response.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
    }
}
