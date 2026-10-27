public import Foundation
import Synchronization

/// URLSessionで通信する。アプリでURLSessionを使うのは、このファイルだけにする（`make lint`の`url_session_outside_network_layer`で止める）。
/// ほかの場所でURLSessionを直接使うと、`HTTPClient`の決まり（再開の時刻、送り直し、大きさの上限）を通らない経路ができるため。
///
/// httpとhttps以外のURLは送らない。URLSessionは`file:`や`data:`も読めるため、サーバーが返したURLで端末のファイルを読みに行かないようにする。
/// 別のホストへリダイレクトされたときは、URLSessionが`Authorization`を外して送る（macOSで、127.0.0.1からlocalhostへの302で確かめた）。
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let downloadDirectory: URL

    /// - Parameter downloadDirectory: `download`が本文を書くフォルダー。
    public init(downloadDirectory: URL = .temporaryDirectory) {
        session = .shared
        self.downloadDirectory = downloadDirectory
    }

    /// 応答のキャッシュ。この通信の口は`URLSession.shared`を使うので、その設定のキャッシュ。設定のストレージの画面で、大きさを出して消すのに使う。
    public static var responseCache: URLCache? {
        URLSession.shared.configuration.urlCache
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (body, response) = try await open(request, limit: .max)
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
        }
        // 取り消されると、列は失敗せずに終わる。途中までの本文を、受け取り終えたものとして返さない。
        try Task.checkCancellation()
        return (data, response)
    }

    public func open(_ request: URLRequest, limit: Int) async throws -> (HTTPResponseBody, HTTPURLResponse) {
        try Self.checkScheme(of: request, allowing: ["http", "https"])
        let (body, continuation) = HTTPResponseBody.makeStream()
        let receiver = ResponseReceiver(body: continuation, limit: limit, uploadProgress: UploadProgress.report)
        let task: URLSessionTask
        if UploadProgress.report != nil, let httpBody = request.httpBody {
            var request = request
            request.httpBody = nil
            task = session.uploadTask(with: request, from: httpBody)
        } else {
            task = session.dataTask(with: request)
        }
        task.delegate = receiver
        // 本文を読むのをやめたら、残りを受け取らずに止める。
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
        let response = try await withTaskCancellationHandler {
            try await receiver.response()
        } onCancel: {
            task.cancel()
        }
        return (body, response)
    }

    /// 本文を、届いたその場で自分で作ったファイルへ書く。URLSessionのダウンロードのタスクは、止めたり失敗したりすると、
    /// 書きかけの`CFNetworkDownload_*.tmp`を一時フォルダーに残し、その場所を公開の形で教えないため使わない。
    /// 上限を超えたとき、接続が切れたとき、取り消されたときは、書きかけのファイルを消してから投げる。
    public func download(_ request: URLRequest, limit: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        try Self.checkScheme(of: request, allowing: ["http", "https"])
        let file = downloadDirectory.appending(fileName: SafeFileName("Download-\(UUID().uuidString)"))
        guard FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let receiver = DownloadReceiver(file: try FileHandle(forWritingTo: file), limit: limit, progress: progress)
            let task = session.dataTask(with: request)
            task.delegate = receiver
            task.resume()
            let response = try await withTaskCancellationHandler {
                try await receiver.response()
            } onCancel: {
                task.cancel()
            }
            return (file, response)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    static func checkScheme(of request: URLRequest, allowing schemes: Set<String>) throws {
        guard let scheme = request.url?.scheme?.lowercased(), schemes.contains(scheme) else {
            throw URLError(.unsupportedURL)
        }
    }
}

/// 応答の頭を待つ呼び出しに渡し、本文を届いた分から列に流す。タスクごとに作る。
/// 列は読む側を待たずに溜まるため、受け取った量が`limit`を超えたら、その時点で止めて溜めるのをやめる。
private final class ResponseReceiver: NSObject, URLSessionDataDelegate, Sendable {
    private enum Head {
        case waiting(CheckedContinuation<HTTPURLResponse, any Error>?)
        case arrived(HTTPURLResponse)
        case failed(any Error)
        case delivered
    }

    private let body: HTTPResponseBody.Continuation
    private let limit: Int
    private let uploadProgress: (@Sendable (Double) -> Void)?
    private let head = Mutex(Head.waiting(nil))
    private let received = Mutex(0)

    init(body: HTTPResponseBody.Continuation, limit: Int, uploadProgress: (@Sendable (Double) -> Void)?) {
        self.body = body
        self.limit = limit
        self.uploadProgress = uploadProgress
    }

    /// 応答の頭が届くまで待つ。頭より先に失敗したら投げる。
    func response() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<HTTPURLResponse, any Error>? = head.withLock { head in
                switch head {
                case .arrived(let response):
                    head = .delivered
                    return .success(response)
                case .failed(let error):
                    head = .delivered
                    return .failure(error)
                case .waiting, .delivered:
                    head = .waiting(continuation)
                    return nil
                }
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    private func deliver(_ result: Result<HTTPURLResponse, any Error>) {
        let waiting: CheckedContinuation<HTTPURLResponse, any Error>? = head.withLock { head in
            switch head {
            case .waiting(let continuation?):
                head = .delivered
                return continuation
            case .waiting(nil):
                switch result {
                case .success(let response): head = .arrived(response)
                case .failure(let error): head = .failed(error)
                }
                return nil
            case .arrived, .failed, .delivered:
                return nil
            }
        }
        waiting?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            deliver(.failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }
        deliver(.success(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let previous = received.withLock { received in
            defer { received += data.count }
            return received
        }
        guard previous <= limit else { return }
        guard previous + data.count > limit else {
            body.yield(data)
            return
        }
        // 1回に届く塊は大きいことがあるため、上限を1バイト超えるところまでで切って渡し、超えたことを読む側にも分かるようにする。
        body.yield(data.prefix(limit - previous + 1))
        body.finish(throwing: ResponseTooLarge(limit: limit))
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let uploadProgress, totalBytesExpectedToSend > 0 else { return }
        uploadProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            deliver(.failure(error))
            body.finish(throwing: error)
        } else {
            // 頭のない応答は来ないが、来たら待っている呼び出しを残さない。
            deliver(.failure(URLError(.badServerResponse)))
            body.finish()
        }
    }
}

/// 本文を、届いたその場でファイルへ書く。タスクごとに作る。
/// 書き終えるまで次の塊を受け取らないので、書き込みが通信に追いつかなくても、書いていない本文をメモリに溜めない。
/// 頭の長さか受け取った量が`limit`を超えたら、その時点で止める。
private final class DownloadReceiver: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var file: FileHandle?
        var received: Int64 = 0
        var response: HTTPURLResponse?
        var failure: (any Error)?
        var result: Result<HTTPURLResponse, any Error>?
        var waiting: CheckedContinuation<HTTPURLResponse, any Error>?
    }

    private let limit: Int
    private let progress: @Sendable (Double) -> Void
    private let state: Mutex<State>

    init(file: FileHandle, limit: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.limit = limit
        self.progress = progress
        state = Mutex(State(file: file))
    }

    /// 本文を書き終えるまで待ち、応答の頭を返す。途中で終わったら投げる。投げたときは、ファイルはもう閉じている。
    func response() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<HTTPURLResponse, any Error>? = state.withLock { state in
                guard let result = state.result else {
                    state.waiting = continuation
                    return nil
                }
                return result
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let failure: (any Error)? = state.withLock { state in
            guard let response = response as? HTTPURLResponse else {
                state.failure = URLError(.badServerResponse)
                return state.failure
            }
            guard response.expectedContentLength <= Int64(limit) else {
                state.failure = ResponseTooLarge(limit: limit)
                return state.failure
            }
            state.response = response
            return nil
        }
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let fraction: Double? = state.withLock { state in
            guard state.failure == nil, let file = state.file else { return nil }
            guard state.received + Int64(data.count) <= Int64(limit) else {
                state.failure = ResponseTooLarge(limit: limit)
                return nil
            }
            do {
                try file.write(contentsOf: data)
            } catch {
                state.failure = error
                return nil
            }
            state.received += Int64(data.count)
            let expected = dataTask.countOfBytesExpectedToReceive
            // 圧縮されて届くと、展開した量が頭の長さを超えるので、1で止める。
            return expected > 0 ? min(Double(state.received) / Double(expected), 1) : nil
        }
        if let fraction {
            progress(fraction)
        } else if state.withLock({ $0.failure != nil }) {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (waiting, result): (CheckedContinuation<HTTPURLResponse, any Error>?, Result<HTTPURLResponse, any Error>) = state.withLock { state in
            var result: Result<HTTPURLResponse, any Error>
            if let failure = state.failure ?? error {
                result = .failure(failure)
            } else if let response = state.response {
                result = .success(response)
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            do {
                try state.file?.close()
            } catch {
                if case .success = result { result = .failure(error) }
            }
            state.file = nil
            state.result = result
            defer { state.waiting = nil }
            return (state.waiting, result)
        }
        waiting?.resume(with: result)
    }
}

/// URLSessionでWebSocketを開く。http、https、ws、wssだけを開く。
public struct URLSessionWebSocketConnector: WebSocketConnector {
    private let session: URLSession

    public init() {
        session = .shared
    }

    public func connect(_ request: URLRequest) -> any WebSocketConnection {
        do {
            try URLSessionTransport.checkScheme(of: request, allowing: ["http", "https", "ws", "wss"])
        } catch {
            return FailedWebSocketConnection(error: error)
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

/// 開く前に断った接続。最初の受信やpingで、その失敗を投げる。
private struct FailedWebSocketConnection: WebSocketConnection {
    let error: any Error

    func receive() async throws -> String { throw error }
    func send(_ text: String) async throws { throw error }
    func ping() async throws { throw error }
    func close() {}
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
            throw handshakeRejection() ?? error
        }
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw handshakeRejection() ?? error
        }
    }

    func ping() async throws {
        do {
            try await Self.awaitFirstCompletion(task.sendPing)
        } catch {
            throw handshakeRejection() ?? error
        }
    }

    /// 完了ハンドラが最初に呼ばれるまで待つ。2回目以降の呼び出しは無視する。取り消されたら、呼ばれるのを待たずに`CancellationError`を投げる。
    ///
    /// macOSのURLSessionWebSocketTaskは、pingの応答を待つ間に接続が切れると、`sendPing`の完了ハンドラを違うエラーで2回呼ぶことがある（Code 57のあとに53など）。そのまま続きを再開すると二重の再開でクラッシュする。
    /// 応答が来なければ、完了ハンドラは接続を閉じるまで呼ばれない。取り消しに応じないと、呼び出した側は取り消されても戻れない。
    static func awaitFirstCompletion(_ send: (@escaping @Sendable ((any Error)?) -> Void) -> Void) async throws {
        let pending = PendingContinuation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard pending.hold(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                send { error in
                    if let error {
                        pending.take()?.resume(throwing: error)
                    } else {
                        pending.take()?.resume()
                    }
                }
            }
        } onCancel: {
            pending.take()?.resume(throwing: CancellationError())
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// ハンドシェイクがHTTPのエラーで断られていたら、そのステータスとヘッダー。再開の時刻を読めるよう、ヘッダーも渡す。
    private func handshakeRejection() -> WebSocketHandshakeRejected? {
        guard let response = task.response as? HTTPURLResponse, response.statusCode != 101 else { return nil }
        return WebSocketHandshakeRejected(response: response)
    }
}

/// 続きを1回だけ取り出せるように持つ。持つ前に取り出されたら（取り消されたら）、持たない。
private final class PendingContinuation: Sendable {
    private enum State {
        case waiting
        case holding(CheckedContinuation<Void, any Error>)
        case taken
    }

    private let state = Mutex(State.waiting)

    /// 続きを持つ。すでに取り出されていたら持たずにfalseを返す。
    func hold(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        state.withLock { state in
            guard case .waiting = state else { return false }
            state = .holding(continuation)
            return true
        }
    }

    /// 最初の呼び出しだけ続きを返す。持つ前に呼ばれたら、以後は持たない。
    func take() -> CheckedContinuation<Void, any Error>? {
        state.withLock { state in
            defer { state = .taken }
            guard case .holding(let continuation) = state else { return nil }
            return continuation
        }
    }
}
