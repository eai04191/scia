import Foundation
import Network
import Synchronization
import Testing
import SciaTesting
@testable import SciaCore

/// URLSessionTransportを、ローカルで立てたHTTPサーバーに実際につないで確かめる。
/// 応答が来ないまま固まったら、テストの実行を止めずに失敗させる。上限は待つ長さの見積もりではなく、固まったとみなす長さ。
@Suite(.serialized, .timeLimit(.minutes(1)), .scratch)
struct URLSessionTransportTests {
    @Test func sendsAndReceivesBody() async throws {
        let server = try await LocalHTTPServer(response: Self.response(status: 200, body: "hello", length: true))
        defer { server.stop() }

        let (data, response) = try await URLSessionTransport().send(URLRequest(url: server.url))

        #expect(response.statusCode == 200)
        #expect(data == Data("hello".utf8))
    }

    /// 2xx以外も、本文とともに返す。分けるのは`HTTPClient`の役目。
    @Test func returnsErrorStatus() async throws {
        let server = try await LocalHTTPServer(response: Self.response(status: 429, headers: "Retry-After: 30\r\n", body: "busy", length: true))
        defer { server.stop() }

        let (data, response) = try await URLSessionTransport().send(URLRequest(url: server.url))

        #expect(response.statusCode == 429)
        #expect(response.value(forHTTPHeaderField: "Retry-After") == "30")
        #expect(data == Data("busy".utf8))
    }

    /// 長さを先に知らせない応答も、上限を超えた時点で読むのをやめる。
    @Test func stopsReadingWhenBodyExceedsLimit() async throws {
        let server = try await LocalHTTPServer(response: Self.response(status: 200, body: String(repeating: "a", count: 64 * 1_024), length: false))
        defer { server.stop() }

        await #expect(throws: ResponseTooLarge(limit: 1_024)) {
            try await HTTPClient(transport: URLSessionTransport()).data(for: URLRequest(url: server.url), limit: 1_024, scope: .host)
        }
    }

    /// 本文を届いた分から渡す口も、読む側が追いつかないうちに上限を超えて溜め込まない。超えたら止めて失敗を流す。
    @Test func openStopsBufferingOverLimit() async throws {
        let server = try await LocalHTTPServer(response: Self.response(status: 200, body: String(repeating: "a", count: 4 * 1_024 * 1_024), length: false))
        defer { server.stop() }

        let (body, _) = try await URLSessionTransport().open(URLRequest(url: server.url), limit: 1_024)
        var received = 0
        await #expect(throws: ResponseTooLarge(limit: 1_024)) {
            for try await chunk in body {
                received += chunk.count
            }
        }
        #expect(received <= 1_024 + 1, "上限を超えても受け取り続けました: \(received)バイト")
    }

    @Test func downloadsToFile() async throws {
        let server = try await LocalHTTPServer(response: Self.response(status: 200, body: "file", length: true))
        defer { server.stop() }
        let folder = try Self.makeDownloadFolder()

        let (file, response) = try await URLSessionTransport(downloadDirectory: folder).download(URLRequest(url: server.url), limit: 1_024) { _ in }

        #expect(response.statusCode == 200)
        #expect(file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(try Data(contentsOf: file) == Data("file".utf8))
    }

    /// 上限を超えて止めたら、落としかけのファイルを残さない。長さを先に知らせる応答も、知らせない応答も。
    @Test(arguments: [true, false])
    func stopsDownloadOverLimit(length: Bool) async throws {
        let server = try await LocalHTTPServer(response: Self.response(status: 200, body: String(repeating: "a", count: 64 * 1_024), length: length))
        defer { server.stop() }
        let folder = try Self.makeDownloadFolder()

        await #expect(throws: ResponseTooLarge(limit: 1_024)) {
            _ = try await URLSessionTransport(downloadDirectory: folder).download(URLRequest(url: server.url), limit: 1_024) { _ in }
        }
        #expect(try Self.contents(of: folder) == [])
    }

    /// 本文の途中で接続が切れたら、落としかけのファイルを残さない。
    @Test func removesPartialDownloadWhenConnectionDrops() async throws {
        let partial = Data("HTTP/1.1 200 Status\r\nContent-Length: \(64 * 1_024)\r\nConnection: close\r\n\r\n\(String(repeating: "a", count: 1_024))".utf8)
        let server = try await LocalHTTPServer(response: partial)
        defer { server.stop() }
        let folder = try Self.makeDownloadFolder()

        await #expect(throws: (any Error).self) {
            _ = try await URLSessionTransport(downloadDirectory: folder).download(URLRequest(url: server.url), limit: 1_024 * 1_024) { _ in }
        }
        #expect(try Self.contents(of: folder) == [])
    }

    /// 落とす途中で取り消されたら、落としかけのファイルを残さない。
    @Test func removesPartialDownloadWhenCancelled() async throws {
        let partial = Data("HTTP/1.1 200 Status\r\nContent-Length: \(64 * 1_024)\r\n\r\n\(String(repeating: "a", count: 1_024))".utf8)
        let server = try await LocalHTTPServer(response: partial, closesAfterResponse: false)
        defer { server.stop() }
        let folder = try Self.makeDownloadFolder()
        let started = Gate()

        let download = Task {
            try await URLSessionTransport(downloadDirectory: folder).download(URLRequest(url: server.url), limit: 1_024 * 1_024) { fraction in
                if fraction > 0 { started.open() }
            }
        }
        try await started.wait()
        download.cancel()

        await #expect(throws: (any Error).self) { _ = try await download.value }
        #expect(try Self.contents(of: folder) == [])
    }

    /// サーバーが返したURLで、端末のファイルを読まない。
    @Test(arguments: ["file:///etc/hosts", "data:text/plain,hello"])
    func refusesNonNetworkScheme(_ string: String) async throws {
        let request = URLRequest(url: try #require(URL(string: string)))
        await #expect(throws: URLError(.unsupportedURL)) { _ = try await URLSessionTransport().send(request) }
        await #expect(throws: URLError(.unsupportedURL)) { _ = try await URLSessionTransport().download(request, limit: 1_024) { _ in } }
    }

    /// - Parameter length: falseなら`Content-Length`を付けず、接続を閉じて本文の終わりを知らせる。
    private static func response(status: Int, headers: String = "", body: String, length: Bool) -> Data {
        let lengthHeader = length ? "Content-Length: \(body.utf8.count)\r\n" : ""
        return Data("HTTP/1.1 \(status) Status\r\n\(headers)\(lengthHeader)Connection: close\r\n\r\n\(body)".utf8)
    }

    private static func makeDownloadFolder() throws -> URL {
        let folder = TestScratch.url("URLSessionTransportTests")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func contents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
    }
}

/// 接続してきた相手に、決まった応答を書いて閉じるHTTPサーバー。`closesAfterResponse`がfalseなら、書いたあとも閉じずに止めるまで待たせる。
private final class LocalHTTPServer: Sendable {
    private let listener: NWListener
    private let connections = HTTPConnections()
    let url: URL

    init(response: Data, closesAfterResponse: Bool = true) async throws {
        let queue = DispatchQueue(label: "LocalHTTPServer")
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let connections = connections
        listener.newConnectionHandler = { connection in
            connections.value.withLock { $0.append(connection) }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in
                    if closesAfterResponse { connection.cancel() }
                })
            }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>
                switch state {
                case .ready: result = .success(listener.port?.rawValue ?? 0)
                case .failed(let error): result = .failure(error)
                default: return
                }
                let isFirst = resumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                if isFirst {
                    continuation.resume(with: result)
                }
            }
            listener.start(queue: queue)
        }
        url = try #require(URL(string: "http://127.0.0.1:\(port)/file"))
    }

    func stop() {
        listener.cancel()
        connections.value.withLock { connections in
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

private final class HTTPConnections: Sendable {
    let value = Mutex<[NWConnection]>([])
}
