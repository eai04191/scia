import Foundation
import Network
import Synchronization
import Testing
@testable import SciaCore

/// URLSessionWebSocketConnectorを、ローカルで立てたWebSocketサーバーに実際につないで確かめる。
@Suite(.serialized)
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

    @Test func rejectedHandshakeIsReportedAsAPIErrorFromPing() async throws {
        let server = try await LocalWebSocketServer(rejectingWith: 401)
        defer { server.stop() }

        let connection = URLSessionWebSocketConnector().connect(URLRequest(url: server.url))
        defer { connection.close() }

        let error = await #expect(throws: MastodonAPIError.self) { try await connection.ping() }
        #expect(error?.isUnauthorized == true)
    }

    @Test func rejectedHandshakeIsReportedAsAPIError() async throws {
        let server = try await LocalWebSocketServer(rejectingWith: 401)
        defer { server.stop() }

        let connection = URLSessionWebSocketConnector().connect(URLRequest(url: server.url))
        defer { connection.close() }

        let error = await #expect(throws: MastodonAPIError.self) { _ = try await connection.receive() }
        #expect(error?.isUnauthorized == true)
    }
}

/// 接続してきた相手に決まったテキストメッセージを送る、またはハンドシェイクをHTTPのエラーで断るWebSocketサーバー。
private final class LocalWebSocketServer: Sendable {
    private let listener: NWListener
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
        }
    }

    /// Network.frameworkのWebSocketは拒否してもHTTPの応答を返さないため、TCPのまま応答を書く。
    convenience init(rejectingWith statusCode: Int) async throws {
        try await self.init(parameters: .tcp, queue: DispatchQueue(label: "LocalWebSocketServer"), authorization: ReceivedHeader()) { connection in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let response = "HTTP/1.1 \(statusCode) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private init(
        parameters: NWParameters,
        queue: DispatchQueue,
        authorization: ReceivedHeader,
        handle: @escaping @Sendable (NWConnection) -> Void
    ) async throws {
        self.authorization = authorization
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in
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
    }
}

private final class ReceivedHeader: Sendable {
    let value = Mutex<String?>(nil)
}

private final class ResumeFlag: Sendable {
    let value = Mutex(false)
}
