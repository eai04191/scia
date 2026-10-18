public import Foundation
import Synchronization

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

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw handshakeError() ?? error
        }
    }

    func ping() async throws {
        do {
            try await Self.awaitFirstCompletion(task.sendPing)
        } catch {
            throw handshakeError() ?? error
        }
    }

    /// 完了ハンドラが最初に呼ばれるまで待つ。2回目以降の呼び出しは無視する。
    ///
    /// macOSのURLSessionWebSocketTaskは、pingの応答を待つ間に接続が切れると、`sendPing`の完了ハンドラを違うエラーで2回呼ぶことがある（Code 57のあとに53など）。そのまま続きを再開すると二重の再開でクラッシュする。
    static func awaitFirstCompletion(_ send: (@escaping @Sendable ((any Error)?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let pending = PendingContinuation(continuation)
            send { error in
                if let error {
                    pending.take()?.resume(throwing: error)
                } else {
                    pending.take()?.resume()
                }
            }
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

/// 続きを1回だけ取り出せるように持つ。
private final class PendingContinuation: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, any Error>?>

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = Mutex(continuation)
    }

    /// 最初の呼び出しだけ続きを返す。
    func take() -> CheckedContinuation<Void, any Error>? {
        continuation.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }
    }
}
