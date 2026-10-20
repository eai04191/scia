#if DEBUG
import Foundation
import os
import SciaCore
import Synchronization

/// 撮影モードの台本。サーバーが返す一覧と、URLで起こすイベントを持つ。
struct ScenarioScript: Sendable {
    /// ページを分けて返す一覧の1件。IDの新しい順に並べる。
    struct Item: Sendable {
        let id: String
        let json: Data
    }

    let credential: Credential
    /// GETで、そのまま返すJSON。キーは`api/v1/accounts/verify_credentials`のようなパス。
    let responses: [String: Data]
    /// `max_id`などで区切って返す一覧。キーはパス。
    let lists: [String: [Item]]
    /// `scia-debug://scenario/<名前>`で流す、ストリーミングのメッセージ。流した時刻を受け取って作り、`interval`おきに1つずつ流す。
    let events: [String: @Sendable (Date) -> [String]]
    let interval: Duration
}

/// 撮影モードで、Mastodonのサーバーの代わりに台本どおりに答える。
final class ScenarioServer: Sendable {
    let script: ScenarioScript
    private let mailbox = Mutex<ScenarioMailbox?>(nil)
    private let logger = SciaLog.logger(category: "scenario")

    init(script: ScenarioScript) {
        self.script = script
    }

    var transport: any HTTPTransport { ScenarioTransport(script: script) }
    var connector: any WebSocketConnector { ScenarioWebSocketConnector(server: self) }

    /// 新しいストリーミングの接続を開く。イベントは、いちばん新しい接続に流す。
    fileprivate func openConnection() -> any WebSocketConnection {
        let mailbox = ScenarioMailbox()
        self.mailbox.withLock { $0 = mailbox }
        logger.info("scenario streaming connected")
        return ScenarioWebSocketConnection(mailbox: mailbox)
    }

    /// 台本のイベントを、ストリーミングで流す。
    func emit(_ name: String) {
        guard let make = script.events[name] else {
            logger.error("scenario unknown event: \(name, privacy: .public)")
            return
        }
        guard let mailbox = mailbox.withLock({ $0 }) else {
            logger.error("scenario event without streaming: \(name, privacy: .public)")
            return
        }
        logger.info("scenario emit \(name, privacy: .public)")
        let messages = make(Date())
        let interval = script.interval
        Task {
            for (index, message) in messages.enumerated() {
                if index > 0 {
                    try? await Task.sleep(for: interval)
                }
                await mailbox.post(message)
            }
        }
    }
}

/// 台本の`responses`と`lists`を返すHTTPTransport。台本にないAPIには404を返し、ログに残す。
private struct ScenarioTransport: HTTPTransport {
    let script: ScenarioScript
    private let logger = SciaLog.logger(category: "scenario")

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let path = String(url.path(percentEncoded: false).drop { $0 == "/" })
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if request.httpMethod == "POST", path == "api/v1/markers" {
            return try respond(url, Data("{}".utf8))
        }
        if let items = script.lists[path] {
            return try respond(url, Self.page(of: items, query: query))
        }
        if request.httpMethod ?? "GET" == "GET", let data = script.responses[path] {
            return try respond(url, data)
        }
        logger.error("scenario no response: \(request.httpMethod ?? "GET", privacy: .public) \(path, privacy: .public)")
        return try respond(url, Data(#"{"error":"Record not found"}"#.utf8), statusCode: 404)
    }

    /// Mastodonと同じく、`max_id`より古い、`since_id`より新しい、`min_id`のすぐ後の、`limit`件を新しい順に返す。
    /// IDは桁をそろえて作るので、文字列の大小で比べる。
    static func page(of items: [ScenarioScript.Item], query: [URLQueryItem]) -> Data {
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let limit = value("limit").flatMap(Int.init) ?? 20
        var selected = items
        if let maxID = value("max_id") { selected = selected.filter { $0.id < maxID } }
        if let sinceID = value("since_id") { selected = selected.filter { $0.id > sinceID } }
        if let minID = value("min_id") {
            selected = Array(selected.filter { $0.id > minID }.suffix(limit))
        } else {
            selected = Array(selected.prefix(limit))
        }
        return Data("[".utf8) + Data(selected.map(\.json).joined(separator: Data(",".utf8))) + Data("]".utf8)
    }

    private func respond(_ url: URL, _ data: Data, statusCode: Int = 200) throws -> (Data, HTTPURLResponse) {
        guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

private struct ScenarioWebSocketConnector: WebSocketConnector {
    let server: ScenarioServer

    func connect(_ request: URLRequest) -> any WebSocketConnection {
        server.openConnection()
    }
}

private struct ScenarioWebSocketConnection: WebSocketConnection {
    let mailbox: ScenarioMailbox

    func receive() async throws -> String {
        try await mailbox.next()
    }

    /// 購読の申し込み。台本はどの購読にもイベントを流すので、受け取るだけにする。
    func send(_ text: String) async throws {}

    func ping() async throws {}

    func close() {
        Task { await mailbox.close() }
    }
}

/// 流したメッセージを、受け取られるまで溜める。
private actor ScenarioMailbox {
    private var queued: [String] = []
    private var waiting: CheckedContinuation<String, any Error>?
    private var isClosed = false

    func post(_ message: String) {
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: message)
        } else {
            queued.append(message)
        }
    }

    func next() async throws -> String {
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        if isClosed {
            throw URLError(.networkConnectionLost)
        }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func close() {
        isClosed = true
        waiting?.resume(throwing: URLError(.networkConnectionLost))
        waiting = nil
    }
}
#endif
