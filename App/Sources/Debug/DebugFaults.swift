#if DEBUG
import Foundation
import os
import SciaCore
import Synchronization

/// 検証のため、APIの応答をわざと失敗させる。起動し直すと戻る。
enum DebugFaults {
    /// 立てると、以後のREST APIのリクエストに401を返す。トークンが無効になった状態を、ログインし直さずに再現する。
    private static let rejectsAsUnauthorized = Mutex(false)

    static var isRejectingAsUnauthorized: Bool { rejectsAsUnauthorized.withLock { $0 } }

    static func rejectAsUnauthorized() {
        rejectsAsUnauthorized.withLock { $0 = true }
    }

    /// 決めると、以後のREST APIのリクエストに、そのステータスコードとHTMLのエラーページを返す。プロキシやサーバーの障害を再現する。
    private static let failingStatusCode = Mutex<(statusCode: Int, retryAfter: Int?)?>(nil)

    static var failingStatus: (statusCode: Int, retryAfter: Int?)? { failingStatusCode.withLock { $0 } }

    /// - Parameter statusCode: nilなら戻す。
    /// - Parameter retryAfter: `Retry-After`ヘッダーで返す秒数。
    static func fail(withStatus statusCode: Int?, retryAfter: Int? = nil) {
        failingStatusCode.withLock { $0 = statusCode.map { ($0, retryAfter) } }
    }

    /// 入れた機能のAPIに、以後は404のHTMLを返す。その機能を実装していないサーバーを再現する。
    private static let unsupportedFeatures = Mutex<Set<OptionalFeature>>([])

    static func makeUnsupported(_ feature: OptionalFeature) {
        unsupportedFeatures.withLock { _ = $0.insert(feature) }
    }

    /// そのリクエストが、実装していないことにした機能のAPIへのものか。
    static func isUnsupported(_ request: URLRequest) -> Bool {
        let path = request.url?.path() ?? ""
        return unsupportedFeatures.withLock { features in
            features.contains { feature in
                switch feature {
                case .markers: path.hasSuffix("api/v1/markers")
                case .preferences: path.hasSuffix("api/v1/preferences")
                case .instanceV2: path.hasSuffix("api/v2/instance")
                }
            }
        }
    }

    /// 立てると、以後のホームと通知の応答のうち、3件に1件を読めない形に壊す。読めなかった投稿や通知の行を、実際の読み込みの経路で確かめる。
    private static let corruptsListElements = Mutex(false)

    static var isCorruptingListElements: Bool { corruptsListElements.withLock { $0 } }

    static func corruptListElements() {
        corruptsListElements.withLock { $0 = true }
    }

    /// 決めると、以後の共有や保存のためのダウンロードを、進み具合を刻みながらその時間だけ遅らせる。ダウンロード中の知らせを、大きなファイルを用意せずに確かめる。
    private static let downloadDelay = Mutex<Duration?>(nil)

    static var slowDownloadDelay: Duration? { downloadDelay.withLock { $0 } }

    /// - Parameter delay: nilなら戻す。
    static func slowDownloads(by delay: Duration?) {
        downloadDelay.withLock { $0 = delay }
    }

    /// 下ろすと、開いているストリーミングの接続を切り、以後の接続を失敗させる。RESTは通したまま、ストリーミングだけがつながらないサーバーを再現する。
    private static let streaming = Mutex((isOnline: true, nextID: 0, connections: [Int: any WebSocketConnection]()))

    static var isStreamingOnline: Bool { streaming.withLock { $0.isOnline } }

    static func setStreamingOnline(_ isOnline: Bool) {
        let cut = streaming.withLock { state in
            state.isOnline = isOnline
            return isOnline ? [] : Array(state.connections.values)
        }
        cut.forEach { $0.close() }
    }

    /// 開いている間だけ覚え、下ろしたときに切れるようにする。閉じたら外す。
    static func track(_ connection: any WebSocketConnection) -> any WebSocketConnection {
        let id = streaming.withLock { state in
            defer { state.nextID += 1 }
            state.connections[state.nextID] = connection
            return state.nextID
        }
        return TrackedWebSocketConnection(base: connection) {
            streaming.withLock { _ = $0.connections.removeValue(forKey: id) }
        }
    }

    /// 配列の3件に1件の`created_at`を、日時として読めない値に変える。IDとURLは残すので、読めなかった行として並ぶ。
    static func corrupt(_ data: Data) -> Data {
        guard var elements = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return data }
        for index in elements.indices where index % 3 == 1 {
            elements[index]["created_at"] = "壊れた日時"
        }
        return (try? JSONSerialization.data(withJSONObject: elements)) ?? data
    }
}

/// `DebugFaults`に従って失敗を返すHTTPTransport。
struct FaultInjectingTransport: HTTPTransport {
    let base: any HTTPTransport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if DebugFaults.isRejectingAsUnauthorized,
           let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil) {
            return (Data(#"{"error":"The access token is invalid"}"#.utf8), response)
        }
        if let (statusCode, retryAfter) = DebugFaults.failingStatus,
           let url = request.url,
           let response = HTTPURLResponse(
               url: url,
               statusCode: statusCode,
               httpVersion: nil,
               headerFields: ["Content-Type": "text/html"].merging(retryAfter.map { ["Retry-After": String($0)] } ?? [:]) { first, _ in first }
           ) {
            return (Data("<html><body><h1>\(statusCode)</h1><p>nginx</p></body></html>".utf8), response)
        }
        if DebugFaults.isUnsupported(request),
           let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "text/html"]) {
            SciaLog.logger(category: "debug").info("debug unsupported \(url.path(), privacy: .public)")
            return (Data("<html><body><h1>404 Not Found</h1></body></html>".utf8), response)
        }
        let (data, response) = try await base.send(request)
        let path = request.url?.path() ?? ""
        if DebugFaults.isCorruptingListElements, path.hasSuffix("api/v1/timelines/home") || path.hasSuffix("api/v1/notifications") {
            return (DebugFaults.corrupt(data), response)
        }
        return (data, response)
    }
}
/// `DebugFaults`に従って、ストリーミングの接続を失敗させるWebSocketConnector。
struct FaultInjectingWebSocketConnector: WebSocketConnector {
    let base: any WebSocketConnector

    func connect(_ request: URLRequest) -> any WebSocketConnection {
        guard DebugFaults.isStreamingOnline else { return UnreachableWebSocketConnection() }
        return DebugFaults.track(base.connect(request))
    }
}

/// 閉じたときに`DebugFaults`の記録から外す接続。
private struct TrackedWebSocketConnection: WebSocketConnection {
    let base: any WebSocketConnection
    let onClose: @Sendable () -> Void

    func receive() async throws -> String {
        try await base.receive()
    }

    func ping() async throws {
        try await base.ping()
    }

    func close() {
        onClose()
        base.close()
    }
}

/// ハンドシェイクで失敗する接続。
private struct UnreachableWebSocketConnection: WebSocketConnection {
    func receive() async throws -> String {
        throw URLError(.cannotConnectToHost)
    }

    func ping() async throws {
        throw URLError(.cannotConnectToHost)
    }

    func close() {}
}
#endif
