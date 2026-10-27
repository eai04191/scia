import Foundation
import Network
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// URLSessionWebSocketConnectorを、ローカルで立てたWebSocketサーバーに実際につないで確かめる。
/// URLSessionのpingは、応答が来なければいつまでも終わらない。本番はReconnectingStreamが時間で打ち切るが、ここでは直接待つため、
/// 応答が来ないまま固まったら、テストの実行を止めずに失敗させる。上限は待つ長さの見積もりではなく、固まったとみなす長さ。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct URLSessionWebSocketTests {
    @Test func receivesTextMessagesAndSendsAuthorizationHeader() async throws {
        let server = try await LocalWebSocketServer(messages: ["first", "second"])
        defer { server.stop() }
        var request = URLRequest(url: server.url)
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")

        let connection = URLSessionWebSocketConnector().connect(request)
        defer { connection.close() }

        #expect(try await connection.receive() == "first")
        #expect(try await connection.receive() == "second")
        // 本番と同じく、受信を待ったままpingを送る。メッセージを読んだあと受信を待たずにpingだけを送ると、
        // ほかのテストと並べて走らせたときに、応答が来ないまま終わらないことがあった（全体のテストを100回走らせて5回）。受信を待つ形では200回とも返った。
        let receiving = Task { try? await connection.receive() }
        defer { receiving.cancel() }
        try await connection.ping()
        #expect(server.receivedAuthorization == "Bearer token")
    }

    @Test func pingIsAnsweredBeforeAnyReceive() async throws {
        let server = try await LocalWebSocketServer(messages: [])
        defer { server.stop() }

        let connection = URLSessionWebSocketConnector().connect(URLRequest(url: server.url))
        defer { connection.close() }

        try await connection.ping()
    }

    /// 接続が切れると、URLSessionはpingの完了ハンドラを違うエラーで2回呼ぶことがある。最初のエラーで1回だけ終わる。
    @Test func pingCompletionCalledTwiceThrowsFirstErrorOnce() async throws {
        let error = await #expect(throws: POSIXError.self) {
            try await URLSessionWebSocketConnection.awaitFirstCompletion { completion in
                completion(POSIXError(.ENOTCONN))
                completion(POSIXError(.ECONNABORTED))
            }
        }
        #expect(error?.code == .ENOTCONN)
    }

    /// 応答の来ないpingも、取り消したら待つのをやめる。待ち続けると、スイートの時間制限で取り消しても、テストの実行全体が終わらなくなる。
    @Test func pingWithoutCompletionEndsWhenCancelled() async throws {
        let sent = ResumeFlag()
        let pinging = Task {
            try await URLSessionWebSocketConnection.awaitFirstCompletion { _ in
                sent.value.withLock { $0 = true }
            }
        }
        try await waitUntil { sent.value.withLock { $0 } }
        pinging.cancel()
        // 終わらないまま待つと、このテストも止まるので、終わったかを条件で待つ。
        let outcome = PingOutcome()
        Task {
            let result = await pinging.result
            outcome.value.withLock { $0 = result }
        }
        try await waitUntil { outcome.value.withLock { $0 != nil } }
        #expect(throws: CancellationError.self) { try outcome.value.withLock { $0 }?.get() }
    }

    @Test func rejectedHandshakeIsReportedFromPing() async throws {
        let server = try await LocalWebSocketServer(rejectingWith: 401)
        defer { server.stop() }

        let connection = URLSessionWebSocketConnector().connect(URLRequest(url: server.url))
        defer { connection.close() }

        let error = await #expect(throws: WebSocketHandshakeRejected.self) { try await connection.ping() }
        #expect(error?.statusCode == 401)
    }

    /// 再開の時刻を読めるよう、断った応答のヘッダーも渡す。
    @Test func rejectedHandshakeCarriesHeaders() async throws {
        let server = try await LocalWebSocketServer(rejectingWith: 429, headers: "Retry-After: 30\r\n")
        defer { server.stop() }

        let connection = URLSessionWebSocketConnector().connect(URLRequest(url: server.url))
        defer { connection.close() }

        let error = await #expect(throws: WebSocketHandshakeRejected.self) { _ = try await connection.receive() }
        #expect(error?.statusCode == 429)
        #expect(error?.header("retry-after") == "30")
    }

    /// サーバーが返したURLで、端末のファイルなどを開かない。
    @Test func refusesNonNetworkScheme() async throws {
        let connection = URLSessionWebSocketConnector().connect(URLRequest(url: URL(filePath: "/etc/hosts")))
        await #expect(throws: URLError(.unsupportedURL)) { _ = try await connection.receive() }
    }
}

/// 接続してきた相手に決まったテキストメッセージを送る、またはハンドシェイクをHTTPのエラーで断るWebSocketサーバー。
private final class LocalWebSocketServer: Sendable {
    private let listener: NWListener
    private let connections: ConnectionList
    private let authorization: ReceivedHeader
    let url: URL

    var receivedAuthorization: String? { authorization.value.withLock { $0 } }

    convenience init(messages: [String]) async throws {
        let queue = DispatchQueue(label: "LocalWebSocketServer")
        let authorization = ReceivedHeader()
        let options = NWProtocolWebSocket.Options()
        // Mastodonのストリーミングサーバーと同じく、pingに応答する。
        options.autoReplyPing = true
        options.setClientRequestHandler(queue) { _, headers in
            authorization.value.withLock { $0 = headers.first { $0.name.lowercased() == "authorization" }?.value }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        try await self.init(parameters: parameters, queue: queue, authorization: authorization) { connection in
            for message in messages {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
                connection.send(content: Data(message.utf8), contentContext: context, completion: .idempotent)
            }
            // 届いたものを読み続ける。pingへの自動の応答は、届いたものを読むときに返すため、読まないと応答するかが内部の都合に左右される。
            Self.receiveContinuously(on: connection)
        }
    }

    /// Network.frameworkのWebSocketは拒否してもHTTPの応答を返さないため、TCPのまま応答を書く。
    convenience init(rejectingWith statusCode: Int, headers: String = "") async throws {
        try await self.init(parameters: .tcp, queue: DispatchQueue(label: "LocalWebSocketServer"), authorization: ReceivedHeader()) { connection in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let response = "HTTP/1.1 \(statusCode) Error\r\n\(headers)Content-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private static func receiveContinuously(on connection: NWConnection) {
        connection.receiveMessage { _, _, _, error in
            guard error == nil else { return }
            receiveContinuously(on: connection)
        }
    }

    private init(
        parameters: NWParameters,
        queue: DispatchQueue,
        authorization: ReceivedHeader,
        handle: @escaping @Sendable (NWConnection) -> Void
    ) async throws {
        self.authorization = authorization
        let connections = ConnectionList()
        self.connections = connections
        parameters.requiredLocalEndpoint = .loopbackWithAnyPort
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            // 送り終えたあとも解放されて閉じないよう、止めるまで持つ。
            connections.value.withLock { $0.append(connection) }
            connection.start(queue: queue)
            handle(connection)
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let resumed = ResumeFlag()
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>
                switch state {
                case .ready:
                    result = .success(listener.port?.rawValue ?? 0)
                case .failed(let error):
                    result = .failure(error)
                default:
                    return
                }
                let isFirst = resumed.value.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                if isFirst {
                    continuation.resume(with: result)
                }
            }
            listener.start(queue: queue)
        }
        url = try #require(URL(string: "ws://127.0.0.1:\(port)/api/v1/streaming"))
    }

    func stop() {
        listener.cancel()
        connections.value.withLock { connections in
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

private final class ConnectionList: Sendable {
    let value = Mutex<[NWConnection]>([])
}

private final class ReceivedHeader: Sendable {
    let value = Mutex<String?>(nil)
}

private final class ResumeFlag: Sendable {
    let value = Mutex(false)
}

private final class PingOutcome: Sendable {
    let value = Mutex<Result<Void, any Error>?>(nil)
}
