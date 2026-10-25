public import Foundation

/// HTTPリクエストを送る口。アプリでは`URLSessionTransport`が実装し、テストではstubに差し替える。
/// 再開の時刻、送り直し、大きさの上限といった決まりは、この口ではなく、これを包む`HTTPClient`が守る。
public protocol HTTPTransport: Sendable {
    /// 応答を、本文までまとめて受け取る。
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// 応答の頭を受け取ったら返し、本文は届いた分から渡す。本文を読むのをやめたら、通信も止める。
    /// 本文が`limit`バイトを超えたら、超えた分を受け取った時点で止め、列を`ResponseTooLarge`で終える。読む側が追いつかなくても、それより多くは溜めない。
    func open(_ request: URLRequest, limit: Int) async throws -> (HTTPResponseBody, HTTPURLResponse)
    /// 本文をファイルへ落とす。`limit`バイトを超えたら止めて`ResponseTooLarge`を投げる。返したファイルは、呼び出し側が動かすか消す。
    /// - Parameter progress: 0から1の進み具合。
    func download(_ request: URLRequest, limit: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse)
}

/// 本文の、届いた分ずつの列。
public typealias HTTPResponseBody = AsyncThrowingStream<Data, any Error>

extension HTTPTransport {
    /// 本文をまとめて受け取ってから渡す。テストの差し替えのように、少しずつ渡す必要のない口で使う。
    public func open(_ request: URLRequest, limit: Int) async throws -> (HTTPResponseBody, HTTPURLResponse) {
        let (data, response) = try await send(request)
        return (HTTPResponseBody { continuation in
            continuation.yield(data)
            continuation.finish(throwing: data.count > limit ? ResponseTooLarge(limit: limit) : nil)
        }, response)
    }

    /// 本文をまとめて受け取ってから、一時ファイルに書く。テストの差し替えのように、少しずつ落とす必要のない口で使う。
    public func download(_ request: URLRequest, limit: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        let (data, response) = try await send(request)
        guard data.count <= limit else { throw ResponseTooLarge(limit: limit) }
        let file = URL.temporaryDirectory.appending(path: "Download-\(UUID().uuidString)")
        try data.write(to: file)
        progress(1)
        return (file, response)
    }
}

/// 本文を送った割合を受け取る。アップロードの進み具合を見せるために、送る呼び出しを包んで値を入れる。
/// 呼び出しの形を変えずに、間の`MastodonClient`や`FaultInjectingTransport`を素通りさせて`URLSessionTransport`まで届けるため、タスクローカルにする。
public enum UploadProgress {
    /// 0から1。送り直したときは、また0から届く。
    @TaskLocal public static var report: (@Sendable (Double) -> Void)?
}
