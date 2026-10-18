public import Foundation

/// HTTPリクエストを送る口。テストではstubに差し替える。
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 本文を送った割合を受け取る。アップロードの進み具合を見せるために、送る呼び出しを包んで値を入れる。
/// 呼び出しの形を変えずに、間の`MastodonClient`や`FaultInjectingTransport`を素通りさせて`URLSessionTransport`まで届けるため、タスクローカルにする。
public enum UploadProgress {
    /// 0から1。送り直したときは、また0から届く。
    @TaskLocal public static var report: (@Sendable (Double) -> Void)?
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        if let report = UploadProgress.report, let body = request.httpBody {
            var request = request
            request.httpBody = nil
            (data, response) = try await session.upload(for: request, from: body, delegate: UploadProgressDelegate(report: report))
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// 本文を送った割合を知らせる。タスクごとに作り、URLSessionが送るたびに呼ぶ。
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
