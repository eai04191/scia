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

    /// 決めると、以後の`target`の通信に、そのステータスコードとHTMLのエラーページを返す。プロキシやサーバーの障害を再現する。
    private static let failingStatusCode = Mutex<(statusCode: Int, retryAfter: Int?, target: Target)?>(nil)

    static var failingStatus: (statusCode: Int, retryAfter: Int?, target: Target)? { failingStatusCode.withLock { $0 } }

    /// 障害を起こす通信の経路。429をどの経路でもシミュレーターで確かめられるよう、アプリの通信はすべて`FaultInjectingTransport`を通る。
    enum Target: String, CaseIterable {
        /// ログインしたサーバーのREST APIとログイン（`/api/`と`/oauth/`）。
        case api
        /// サーバーが中継するほかのサーバーの画像（`/media_proxy/`）。
        case mediaProxy = "media-proxy"
        /// そのほかの画像やファイル、リンク先のページ。
        case files
        /// fxtwitterのXの投稿。
        case x
        /// ストリーミングの接続。つなぐときの応答をそのステータスで断る。
        case streaming
        case all

        /// リクエストがどの経路か。ストリーミングは`FaultInjectingWebSocketConnector`が受けるので、ここでは返さない。
        init(of request: URLRequest) {
            let path = request.url?.path() ?? ""
            if request.url?.host() == "api.fxtwitter.com" {
                self = .x
            } else if path.hasPrefix("/media_proxy/") {
                self = .mediaProxy
            } else if path.hasPrefix("/api/") || path.hasPrefix("/oauth/") {
                self = .api
            } else {
                self = .files
            }
        }

        func covers(_ target: Target) -> Bool {
            self == .all || self == target
        }
    }

    /// - Parameter statusCode: nilなら戻す。
    /// - Parameter retryAfter: `Retry-After`ヘッダーで返す秒数。
    /// - Parameter target: 障害を起こす経路。ストリーミングを含めたら、開いている接続を切り、つなぎ直しで断られるようにする。
    static func fail(withStatus statusCode: Int?, retryAfter: Int? = nil, target: Target = .api) {
        failingStatusCode.withLock { $0 = statusCode.map { ($0, retryAfter, target) } }
        if statusCode != nil, target.covers(.streaming) {
            streaming.withLock { Array($0.connections.values) }.forEach { $0.close() }
        }
    }

    /// `target`の通信に返す、ステータスと`Retry-After`。障害を起こしていなければnil。
    static func failingStatus(for target: Target) -> (statusCode: Int, retryAfter: Int?)? {
        guard let failing = failingStatus, failing.target.covers(target) else { return nil }
        return (failing.statusCode, failing.retryAfter)
    }

    /// 立てると、以後のホームの応答のステータスを206にする。中身はそのまま返すので、サーバーがホームを作り直している最中に一部だけ返した状態になる。
    private static let regeneratesHome = Mutex(false)

    static var isRegeneratingHome: Bool { regeneratesHome.withLock { $0 } }

    static func setRegeneratingHome(_ isOn: Bool) {
        regeneratesHome.withLock { $0 = isOn }
    }

    /// 入れた機能のAPIに、以後は404のHTMLを返す。その機能を実装していないサーバーを再現する。
    private static let unsupportedFeatures = Mutex<Set<OptionalFeature>>([])

    static func makeUnsupported(_ feature: OptionalFeature) {
        unsupportedFeatures.withLock { _ = $0.insert(feature) }
    }

    static func isUnsupported(_ feature: OptionalFeature) -> Bool {
        unsupportedFeatures.withLock { $0.contains(feature) }
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
                case .multipleStatuses: path.hasSuffix("api/v1/statuses") && request.httpMethod == "GET"
                case .multipleAccounts: path.hasSuffix("api/v1/accounts") && request.httpMethod == "GET"
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

    /// 決めると、以後の共有や保存のためのダウンロードを、進み具合を少しずつ進めながらその時間だけ遅らせる。ダウンロード中の知らせを、大きなファイルを用意せずに確かめる。
    private static let downloadDelay = Mutex<Duration?>(nil)

    static var slowDownloadDelay: Duration? { downloadDelay.withLock { $0 } }

    /// - Parameter delay: nilなら戻す。
    static func slowDownloads(by delay: Duration?) {
        downloadDelay.withLock { $0 = delay }
    }

    /// 決めると、以後の投稿のメニューで、まだ読んでいないユーザーのアイコンを、その時間だけ遅らせてから読む。
    /// 一度読んだ画像は端末に残って読み込みがすぐ終わるため、開いている間に記号からアイコンへ替わるところを確かめるのに使う。
    private static let menuIconDelay = Mutex<Duration?>(nil)

    static var slowMenuIconDelay: Duration? { menuIconDelay.withLock { $0 } }

    /// - Parameter delay: nilなら戻す。
    static func slowMenuIcons(by delay: Duration?) {
        menuIconDelay.withLock { $0 = delay }
    }

    /// 決めると、以後のプロフィールを開く操作と、ユーザーのメニューのメンションとハンドルのコピーで、相手を探すのをその時間だけ遅らせる。
    /// 待っている途中に押し直す、タブを移る、「取得中」のチップが出るところを、遅いサーバーを用意せずに確かめるのに使う。
    private static let lookupDelay = Mutex<Duration?>(nil)

    static var slowLookupDelay: Duration? { lookupDelay.withLock { $0 } }

    /// - Parameter delay: nilなら戻す。
    static func slowLookups(by delay: Duration?) {
        lookupDelay.withLock { $0 = delay }
    }

    /// 決めると、以後の投稿欄のメディアのアップロードを、送る前にその時間だけ遅らせる。
    /// 投稿ボタンを押してから準備が済むまでの、待つのをやめる、待つ間に畳む、といった操作を、大きなメディアなしで確かめるため。
    private static let uploadDelay = Mutex<Duration?>(nil)

    static var slowUploadDelay: Duration? { uploadDelay.withLock { $0 } }

    /// - Parameter delay: nilなら戻す。
    static func slowUploads(by delay: Duration?) {
        uploadDelay.withLock { $0 = delay }
    }

    /// 決めると、投稿欄が使うサーバーのメディアの上限のうち、決めた項目だけを差し替える。送る前に縮める流れを、大きなメディアなしで確かめるため。
    private static let mediaLimitsOverrideState = Mutex<MediaLimits?>(nil)

    /// - Parameter limits: nilなら戻す。
    static func overrideMediaLimits(_ limits: MediaLimits?) {
        mediaLimitsOverrideState.withLock { $0 = limits }
    }

    /// 差し替えている上限。差し替えていなければnil。
    static var mediaLimitsOverride: MediaLimits? { mediaLimitsOverrideState.withLock { $0 } }

    /// サーバーの設定の上限に、差し替えた項目を当てる。
    static func applyingMediaLimits(to configuration: InstanceConfiguration?) -> InstanceConfiguration? {
        guard let configuration, let override = mediaLimitsOverrideState.withLock({ $0 }) else { return configuration }
        let server = configuration.mediaLimits
        return InstanceConfiguration(
            streamingURL: configuration.streamingURL,
            maxCharacters: configuration.maxCharacters,
            charactersReservedPerURL: configuration.charactersReservedPerURL,
            maxMediaAttachments: configuration.maxMediaAttachments,
            mediaDescriptionLimit: configuration.mediaDescriptionLimit,
            supportedMediaTypes: configuration.supportedMediaTypes,
            pollLimits: configuration.pollLimits,
            mediaLimits: MediaLimits(
                imageSizeLimit: override.imageSizeLimit ?? server.imageSizeLimit,
                imageMatrixLimit: override.imageMatrixLimit ?? server.imageMatrixLimit,
                videoSizeLimit: override.videoSizeLimit ?? server.videoSizeLimit,
                videoMatrixLimit: override.videoMatrixLimit ?? server.videoMatrixLimit,
                videoFrameRateLimit: override.videoFrameRateLimit ?? server.videoFrameRateLimit
            )
        )
    }

    /// 立てると、ホームと通知のタブは、届いた新着を一覧に挿入せずに溜める。agentが一覧の行をタップする間に、新着で行がずれないようにする。
    private static let holdsArrivals = Mutex(false)

    static var isHoldingArrivals: Bool { holdsArrivals.withLock { $0 } }

    static func setHoldingArrivals(_ isOn: Bool) {
        holdsArrivals.withLock { $0 = isOn }
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
    /// 通知のまとまりの応答では、まとまりの3件に1件の`latest_page_notification_at`を変える。
    static func corrupt(_ data: Data) -> Data {
        let object = try? JSONSerialization.jsonObject(with: data)
        if var results = object as? [String: Any], var groups = results["notification_groups"] as? [[String: Any]] {
            for index in groups.indices where index % 3 == 1 {
                groups[index]["latest_page_notification_at"] = "壊れた日時"
            }
            results["notification_groups"] = groups
            return (try? JSONSerialization.data(withJSONObject: results)) ?? data
        }
        guard var elements = object as? [[String: Any]] else { return data }
        for index in elements.indices where index % 3 == 1 {
            elements[index]["created_at"] = "壊れた日時"
        }
        return (try? JSONSerialization.data(withJSONObject: elements)) ?? data
    }
}

/// `DebugFaults`に従って失敗を返すHTTPTransport。アプリの通信はすべてこれを通る。
/// ダミー投稿と部品カタログが渡す`data:`のURLと、端末の一時フォルダーに書き出したダミーの動画も、ここで返す。
/// 本番の`URLSessionTransport`は、サーバーが返したURLで端末のファイルを読まないよう、httpとhttps以外を断るため。
struct FaultInjectingTransport: HTTPTransport {
    let base: any HTTPTransport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let response = try await injectedResponse(for: request) {
            return response
        }
        return try await modified(base.send(request), for: request)
    }

    func open(_ request: URLRequest, limit: Int) async throws -> (HTTPResponseBody, HTTPURLResponse) {
        if let (data, response) = try await injectedResponse(for: request) {
            return (Self.body(data, limit: limit), response)
        }
        guard rewritesBody(of: request) else { return try await base.open(request, limit: limit) }
        // 本文を書き換える障害は、上限まで受け取ってから書き換えて渡す。
        let (body, response) = try await base.open(request, limit: limit)
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
        }
        let (modifiedData, modifiedResponse) = modified((data, response), for: request)
        return (Self.body(modifiedData, limit: limit), modifiedResponse)
    }

    /// 本文を書き換える障害（壊す、206にする）が、このリクエストに効くか。
    private func rewritesBody(of request: URLRequest) -> Bool {
        let path = request.url?.path() ?? ""
        return (DebugFaults.isCorruptingListElements && (path.hasSuffix("api/v1/timelines/home") || path.hasSuffix("api/v2/notifications")))
            || (DebugFaults.isRegeneratingHome && path.hasSuffix("api/v1/timelines/home"))
    }

    private static func body(_ data: Data, limit: Int) -> HTTPResponseBody {
        HTTPResponseBody { continuation in
            continuation.yield(data)
            continuation.finish(throwing: data.count > limit ? ResponseTooLarge(limit: limit) : nil)
        }
    }

    func download(_ request: URLRequest, limit: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        if let (data, response) = try await injectedResponse(for: request) {
            let file = URL.temporaryDirectory.appending(fileName: SafeFileName("Download-\(UUID().uuidString)"))
            try data.write(to: file)
            progress(1)
            return (file, response)
        }
        return try await base.download(request, limit: limit, progress: progress)
    }

    private typealias Target = DebugFaults.Target

    /// 障害やダミーの応答。本物の通信に任せるときはnil。
    private func injectedResponse(for request: URLRequest) async throws -> (Data, HTTPURLResponse)? {
        // ダミーのサーバーには通信しない。ほかの障害は重ねない。
        if DummyServer.handles(request.url) {
            return await DummyServer.response(for: request)
        }
        guard let url = request.url else { return nil }
        if url.scheme == "data" || (url.isFileURL && url.standardizedFileURL.path().hasPrefix(URL.temporaryDirectory.standardizedFileURL.path())) {
            return (try Data(contentsOf: url), try Self.response(url, statusCode: 200))
        }
        let target = Target(of: request)
        if target == .api, DebugFaults.isRejectingAsUnauthorized {
            return (Data(#"{"error":"The access token is invalid"}"#.utf8), try Self.response(url, statusCode: 401))
        }
        if let (statusCode, retryAfter) = DebugFaults.failingStatus(for: target) {
            let headers = ["Content-Type": "text/html"].merging(retryAfter.map { ["Retry-After": String($0)] } ?? [:]) { first, _ in first }
            return (Data("<html><body><h1>\(statusCode)</h1><p>nginx</p></body></html>".utf8), try Self.response(url, statusCode: statusCode, headers: headers))
        }
        if target == .api, DebugFaults.isUnsupported(request) {
            SciaLog.logger(category: "debug").info("debug unsupported \(url.path(), privacy: .public)")
            return (Data("<html><body><h1>404 Not Found</h1></body></html>".utf8), try Self.response(url, statusCode: 404, headers: ["Content-Type": "text/html"]))
        }
        return nil
    }

    /// 本文の破損とステータスの変更は、同時に入れても両方効かせる。
    private func modified(_ result: (Data, HTTPURLResponse), for request: URLRequest) -> (Data, HTTPURLResponse) {
        var (data, response) = result
        let path = request.url?.path() ?? ""
        if DebugFaults.isCorruptingListElements, path.hasSuffix("api/v1/timelines/home") || path.hasSuffix("api/v2/notifications") {
            data = DebugFaults.corrupt(data)
        }
        if DebugFaults.isRegeneratingHome, path.hasSuffix("api/v1/timelines/home"), response.statusCode == 200,
           let url = response.url,
           let partial = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: response.allHeaderFields as? [String: String]) {
            response = partial
        }
        return (data, response)
    }

    private static func response(_ url: URL, statusCode: Int, headers: [String: String]? = nil) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers) else {
            throw URLError(.badServerResponse)
        }
        return response
    }
}

/// `DebugFaults`に従って、ストリーミングの接続を失敗させるWebSocketConnector。
struct FaultInjectingWebSocketConnector: WebSocketConnector {
    let base: any WebSocketConnector

    func connect(_ request: URLRequest) -> any WebSocketConnection {
        if DummyServer.handles(request.url) { return DummyWebSocketConnection() }
        guard DebugFaults.isStreamingOnline else { return UnreachableWebSocketConnection(error: URLError(.cannotConnectToHost)) }
        if let (statusCode, retryAfter) = DebugFaults.failingStatus(for: .streaming) {
            let headers = retryAfter.map { ["Retry-After": String($0)] } ?? [:]
            return UnreachableWebSocketConnection(error: WebSocketHandshakeRejected(statusCode: statusCode, headers: headers))
        }
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

    func send(_ text: String) async throws {
        try await base.send(text)
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
    let error: any Error

    func receive() async throws -> String {
        throw error
    }

    func send(_ text: String) async throws {
        throw error
    }

    func ping() async throws {
        throw error
    }

    func close() {}
}
#endif
