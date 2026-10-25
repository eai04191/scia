public import Foundation
import Synchronization

/// URLSessionで通信する。アプリでURLSessionを使うのは、このファイルだけにする（`make lint`の`url_session_outside_network_layer`で止める）。
/// ほかの場所でURLSessionを直接使うと、`HTTPClient`の決まり（再開の時刻、送り直し、大きさの上限）を通らない経路ができるため。
///
/// httpとhttps以外のURLは送らない。URLSessionは`file:`や`data:`も読めるため、サーバーが返したURLで端末のファイルを読みに行かないようにする。
/// 別のホストへリダイレクトされたときは、URLSessionが`Authorization`を外して送る（macOSで、127.0.0.1からlocalhostへの302で確かめた）。
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        session = .shared
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

    public func download(_ request: URLRequest, limit: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        try Self.checkScheme(of: request, allowing: ["http", "https"])
        let observer = DownloadObserver(limit: limit, progress: progress)
        let location: URL
        let response: URLResponse
        do {
            (location, response) = try await session.download(for: request, delegate: observer)
        } catch let error as URLError where error.code == .cancelled && observer.isOverLimit {
            throw ResponseTooLarge(limit: limit)
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: location)
            throw URLError(.badServerResponse)
        }
        return (location, http)
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

/// ダウンロードの進み具合を伝え、上限を超えたら止める。非同期の`download(for:delegate:)`では書き込みの通知が届かないため、タスクを見張る。
private final class DownloadObserver: NSObject, URLSessionTaskDelegate, Sendable {
    private let limit: Int
    private let progress: @Sendable (Double) -> Void
    private let state = Mutex<(observation: NSKeyValueObservation?, isOverLimit: Bool)>((nil, false))

    init(limit: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.limit = limit
        self.progress = progress
    }

    var isOverLimit: Bool { state.withLock { $0.isOverLimit } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let limit = limit
        let progress = progress
        let observation = task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] task, _ in
            if task.countOfBytesReceived > limit || task.countOfBytesExpectedToReceive > limit {
                self?.state.withLock { $0.isOverLimit = true }
                task.cancel()
                return
            }
            if task.countOfBytesExpectedToReceive > 0 {
                progress(Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive))
            }
        }
        state.withLock { $0.observation = observation }
    }
}
