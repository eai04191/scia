import Foundation
import SciaTesting
import Synchronization
import Testing
@testable import SciaCore

/// アプリの通信はすべて`HTTPClient`を通り、同じ決まり（docs/network.md）に従う。
@Suite(.scratch)
struct HTTPClientTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    private func client(_ transport: StubTransport, hosts: HostRateLimits? = nil) -> HTTPClient {
        let now = now
        return HTTPClient(
            transport: transport,
            hosts: hosts ?? HostRateLimits(now: { now }, clock: TestClock()),
            retry: RetryPolicy(maxRetries: 2, initialDelay: .zero),
            clock: TestClock(),
            now: { now }
        )
    }

    // MARK: - 大きさの上限

    @Test func readsBodyUpToLimit() async throws {
        let body = Data(repeating: 1, count: 10)
        let (data, _) = try await client(StubTransport([.init(statusCode: 200, body: body)]))
            .data(for: URLRequest(url: try url("https://example.social/a.png")), limit: 10, scope: .host)
        #expect(data == body)
    }

    /// 上限を超えた本文は、読んだ分を返さずに失敗にする。
    @Test func refusesBodyOverLimit() async throws {
        await #expect(throws: ResponseTooLarge(limit: 10)) {
            try await client(StubTransport([.init(statusCode: 200, body: Data(repeating: 1, count: 11))]))
                .data(for: URLRequest(url: try url("https://example.social/a.png")), limit: 10, scope: .host)
        }
    }

    /// 長さを先に知らせる応答は、本文を読まずに断る。
    @Test func refusesDeclaredLengthOverLimit() async throws {
        let response = StubTransport.Response(statusCode: 200, body: Data(), headers: ["Content-Length": "11"])
        await #expect(throws: ResponseTooLarge(limit: 10)) {
            try await client(StubTransport([response])).data(for: URLRequest(url: try url("https://example.social/a.png")), limit: 10, scope: .host)
        }
    }

    /// REST APIにも上限がある。
    @Test func restAPIRefusesResponseOverLimit() async throws {
        let transport = StubTransport([.init(statusCode: 200, body: Data(), headers: ["Content-Length": "\(ResponseLimit.api + 1)"])])
        let client = MastodonClient(credential: try makeCredential(), transport: transport, retry: RetryPolicy(maxRetries: 0, initialDelay: .zero))
        await #expect(throws: ResponseTooLarge(limit: ResponseLimit.api)) { try await client.verifyCredentials() }
    }

    // MARK: - 2xx以外

    /// 2xx以外の本文は渡さず、示された再開までの長さを持つ失敗にする。
    @Test func nonSuccessThrowsStatusWithRetryAfter() async throws {
        let transport = StubTransport([.json("<html>busy</html>", statusCode: 404, headers: ["Retry-After": "30"])])
        await #expect(throws: HTTPStatusError(statusCode: 404, retryAfter: .seconds(30))) {
            try await client(transport).data(for: URLRequest(url: try url("https://example.social/a.png")), limit: 100, scope: .host)
        }
    }

    // MARK: - ホストごとに止める

    /// 429が再開の時刻を示したら、そのホストの自動の通信を、時刻まで送らずに失敗させる。ほかのホストと、使う人の操作は送る。
    @Test func rateLimitedHostPausesAutomaticRequests() async throws {
        let transport = StubTransport([
            .json("", statusCode: 429, headers: ["Retry-After": "60"]),
            .init(statusCode: 200, body: Data([2])),
            .init(statusCode: 200, body: Data([3])),
        ])
        let client = client(transport)
        await #expect(throws: HTTPStatusError(statusCode: 429, retryAfter: .seconds(60))) {
            try await RequestOrigin.$current.withValue(.automatic) {
                _ = try await client.data(for: URLRequest(url: try url("https://files.example.social/1.png")), limit: 100, scope: .host)
            }
        }

        let paused = await #expect(throws: AutomaticRequestsPaused.self) {
            try await RequestOrigin.$current.withValue(.automatic) {
                _ = try await client.data(for: URLRequest(url: try url("https://files.example.social/2.png")), limit: 100, scope: .host)
            }
        }
        #expect(paused?.retryAfter == .seconds(60))
        #expect(await transport.requests.count == 1, "止めている間に送りました")

        let other = try await RequestOrigin.$current.withValue(.automatic) {
            try await client.data(for: URLRequest(url: try url("https://other.example/1.png")), limit: 100, scope: .host)
        }
        #expect(other.0 == Data([2]))
        let user = try await client.data(for: URLRequest(url: try url("https://files.example.social/2.png")), limit: 100, scope: .host)
        #expect(user.0 == Data([3]))
    }

    /// 止めるホストは、絵文字、アイコン、添付ファイルのどのストアから送っても同じ。アプリで1つを共有する。
    @Test func hostPauseIsSharedAcrossClients() async throws {
        let hosts = HostRateLimits(now: { [now] in now }, clock: TestClock())
        let first = client(StubTransport([.json("", statusCode: 503, headers: ["Retry-After": "60"])]), hosts: hosts)
        let second = StubTransport([])
        _ = try? await first.data(for: URLRequest(url: try url("https://files.example.social/emoji.png")), limit: 100, scope: .host)

        await #expect(throws: AutomaticRequestsPaused.self) {
            try await RequestOrigin.$current.withValue(.automatic) {
                _ = try await client(second, hosts: hosts).data(for: URLRequest(url: try url("https://files.example.social/avatar.png")), limit: 100, scope: .host)
            }
        }
    }

    /// `/media_proxy`は、画像のストアがストアごとに止める（docs/image-loading.md）。ここではホストを止めない。
    @Test func mediaProxyDoesNotPauseHost() async throws {
        let transport = StubTransport([
            .json("", statusCode: 429, headers: ["Retry-After": "60"]),
            .init(statusCode: 200, body: Data([1])),
        ])
        let client = client(transport)
        _ = try? await client.data(for: URLRequest(url: try url("https://example.social/media_proxy/1/original")), limit: 100, scope: .host)

        let next = try await RequestOrigin.$current.withValue(.automatic) {
            try await client.data(for: URLRequest(url: try url("https://example.social/system/emoji.png")), limit: 100, scope: .host)
        }
        #expect(next.0 == Data([1]))
    }

    /// 再開の時刻を示さない429は止めない。いつまで止めればよいか分からないため。
    @Test func rateLimitWithoutResumeTimeDoesNotPause() async throws {
        let transport = StubTransport([.json("", statusCode: 429), .init(statusCode: 200, body: Data([1]))])
        let client = client(transport)
        _ = try? await client.data(for: URLRequest(url: try url("https://files.example.social/1.png")), limit: 100, scope: .host)

        let next = try await RequestOrigin.$current.withValue(.automatic) {
            try await client.data(for: URLRequest(url: try url("https://files.example.social/2.png")), limit: 100, scope: .host)
        }
        #expect(next.0 == Data([1]))
    }

    /// 再開の時刻は、本文を読む前に門へ反映する。本文が上限を超えて読めなくても、止める。
    @Test func pausesBeforeReadingOversizedErrorBody() async throws {
        let transport = StubTransport([.json("", statusCode: 429, headers: ["Retry-After": "60", "Content-Length": "1000"])])
        let client = client(transport)
        await #expect(throws: ResponseTooLarge(limit: 100)) {
            _ = try await client.data(for: URLRequest(url: try url("https://files.example.social/1.png")), limit: 100, scope: .host)
        }
        await #expect(throws: AutomaticRequestsPaused.self) {
            try await RequestOrigin.$current.withValue(.automatic) {
                _ = try await client.data(for: URLRequest(url: try url("https://files.example.social/2.png")), limit: 100, scope: .host)
            }
        }
    }

    /// 429が再開の時刻を示したあと、本文の途中で切れても、通信の失敗として送り直さない。時刻より前に送ることになるため。
    @Test func doesNotRetryWhenBodyOfRateLimitIsCut() async throws {
        let transport = ScriptedOpenTransport { request in
            let response = try makeResponse(request.url, statusCode: 429, headers: ["Retry-After": "60"])
            return (HTTPResponseBody { $0.finish(throwing: URLError(.networkConnectionLost)) }, response)
        }
        let client = client(StubTransport([])).withTransport(transport, hosts: HostRateLimits(now: { [now] in now }, clock: TestClock()), retry: RetryPolicy(maxRetries: 2, initialDelay: .zero))
        await #expect(throws: URLError(.networkConnectionLost)) {
            _ = try await client.data(for: URLRequest(url: try url("https://files.example.social/1.png")), limit: 100, scope: .host)
        }
        #expect(transport.requestCount == 1)
        await #expect(throws: AutomaticRequestsPaused.self) {
            try await RequestOrigin.$current.withValue(.automatic) {
                _ = try await client.data(for: URLRequest(url: try url("https://files.example.social/2.png")), limit: 100, scope: .host)
            }
        }
    }

    /// リダイレクトされた先が429を返したら、応答したホストを止める。
    @Test func pausesRespondingHostAfterRedirect() async throws {
        let transport = ScriptedOpenTransport { _ in
            let response = try makeResponse(URL(string: "https://cdn.example.net/1.png"), statusCode: 429, headers: ["Retry-After": "60"])
            return (HTTPResponseBody { $0.finish() }, response)
        }
        let client = client(StubTransport([])).withTransport(transport, hosts: HostRateLimits(now: { [now] in now }, clock: TestClock()), retry: RetryPolicy(maxRetries: 0, initialDelay: .zero))
        _ = try? await client.data(for: URLRequest(url: try url("https://files.example.social/1.png")), limit: 100, scope: .host)

        await #expect(throws: AutomaticRequestsPaused.self) {
            try await RequestOrigin.$current.withValue(.automatic) {
                _ = try await client.data(for: URLRequest(url: try url("https://cdn.example.net/2.png")), limit: 100, scope: .host)
            }
        }
    }

    /// 本文を受け取る途中で取り消したら、途中までの本文を成功として返さない。
    @Test func cancellationWhileReadingBodyThrows() async throws {
        let started = Gate()
        let transport = ScriptedOpenTransport { request in
            let response = try makeResponse(request.url, statusCode: 200)
            return (HTTPResponseBody { continuation in
                continuation.yield(Data([1]))
                started.open()
            }, response)
        }
        let client = client(StubTransport([])).withTransport(transport, hosts: HostRateLimits(), retry: RetryPolicy(maxRetries: 0, initialDelay: .zero))
        let url = try url("https://files.example.social/1.png")
        let task = Task { try await client.data(for: URLRequest(url: url), limit: 100, scope: .host) }
        try await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    /// 取り消された処理からは、新しい通信を送らない。呼び出し側が取り消しを飲み込んで次の読み込みへ進んでも、通信は出ない。
    @Test func doesNotSendFromCancelledTask() async throws {
        let transport = StubTransport([])
        let client = client(transport)
        let url = try url("https://files.example.social/1.png")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.data(for: URLRequest(url: url), limit: 100, scope: .host)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - 送り直し

    /// `/media_proxy`はここでは止めないが、再開の時刻を示した503を、その場で送り直しもしない。止めるのは画像のストアの役目。
    @Test func doesNotRetryMediaProxyServiceUnavailableWithResumeTime() async throws {
        let transport = StubTransport([.json("", statusCode: 503, headers: ["Retry-After": "60"])])
        await #expect(throws: HTTPStatusError(statusCode: 503, retryAfter: .seconds(60))) {
            try await client(transport).data(for: URLRequest(url: try url("https://example.social/media_proxy/1/original")), limit: 100, scope: .host)
        }
        #expect(await transport.requests.count == 1)
    }

    /// APIの外の読み込みも、一時的な失敗ではその場で送り直す。
    @Test func retriesTemporaryFailureOfGet() async throws {
        let transport = StubTransport([.json("", statusCode: 502), .failure(.networkConnectionLost), .init(statusCode: 200, body: Data([1]))])
        let (data, _) = try await client(transport).data(for: URLRequest(url: try url("https://files.example.social/1.png")), limit: 100, scope: .host)
        #expect(data == Data([1]))
        #expect(await transport.requests.count == 3)
    }

    /// 再開の時刻を示した503は、その場で送り直さずに止める側で扱う。
    @Test func doesNotRetryServiceUnavailableWithResumeTime() async throws {
        let transport = StubTransport([.json("", statusCode: 503, headers: ["Retry-After": "60"])])
        await #expect(throws: HTTPStatusError.self) {
            try await client(transport).data(for: URLRequest(url: try url("https://files.example.social/1.png")), limit: 100, scope: .host)
        }
        #expect(await transport.requests.count == 1)
    }

    // MARK: - 少しずつ読む、ファイルへ落とす

    /// 少しずつ読む口も、2xx以外は失敗にし、示された再開の時刻でホストを止める。
    @Test func openPausesHostOnRateLimit() async throws {
        let transport = StubTransport([.json("", statusCode: 429, headers: ["Retry-After": "60"])])
        let client = client(transport)
        await #expect(throws: HTTPStatusError(statusCode: 429, retryAfter: .seconds(60))) {
            _ = try await client.open(URLRequest(url: try url("https://files.example.social/video.mp4")), limit: 100, scope: .host)
        }
        await #expect(throws: AutomaticRequestsPaused.self) {
            try await RequestOrigin.$current.withValue(.automatic) {
                _ = try await client.open(URLRequest(url: try url("https://files.example.social/video.mp4")), limit: 100, scope: .host)
            }
        }
    }

    /// ファイルへ落とす口は、2xx以外の本文をファイルとして残さない。
    @Test func downloadRemovesErrorBody() async throws {
        let transport = RecordingDownloadTransport(statusCode: 500)
        await #expect(throws: HTTPStatusError(statusCode: 500)) {
            _ = try await client(StubTransport([])).withTransport(transport)
                .download(URLRequest(url: try url("https://files.example.social/video.mp4")), limit: 100, scope: .host) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: transport.file.path()))
    }

    private func makeCredential() throws -> Credential {
        Credential(instance: try url("https://example.social"), accessToken: "token", clientID: "id", clientSecret: "secret", accountID: "1", username: "alice")
    }
}

extension HTTPClient {
    /// 同じ決まりのまま、送る口だけを差し替える。
    fileprivate func withTransport(
        _ transport: any HTTPTransport,
        hosts: HostRateLimits = HostRateLimits(),
        retry: RetryPolicy = RetryPolicy(maxRetries: 0, initialDelay: .zero)
    ) -> HTTPClient {
        HTTPClient(transport: transport, hosts: hosts, retry: retry, clock: TestClock(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }
}

/// エラーの本文をファイルに落とす口。消されたかを確かめられるよう、書いたファイルを覚える。
private final class RecordingDownloadTransport: HTTPTransport {
    let statusCode: Int
    let file = TestScratch.url("RecordingDownloadTransport")

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }

    func download(_ request: URLRequest, limit: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        try Data("<html>error</html>".utf8).write(to: file)
        let url = try #require(request.url)
        return (file, try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)))
    }
}

/// 応答の頭を作る。作れなければ投げる。
private func makeResponse(_ url: URL?, statusCode: Int, headers: [String: String]? = nil) throws -> HTTPURLResponse {
    guard let url, let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers) else {
        throw URLError(.badURL)
    }
    return response
}

/// 応答の頭と本文の列を、テストが決める口。本文の途中で切れる、リダイレクトされる、といった形を作る。
private final class ScriptedOpenTransport: HTTPTransport {
    private let respond: @Sendable (URLRequest) throws -> (HTTPResponseBody, HTTPURLResponse)
    private let count = Mutex(0)

    init(_ respond: @escaping @Sendable (URLRequest) throws -> (HTTPResponseBody, HTTPURLResponse)) {
        self.respond = respond
    }

    var requestCount: Int { count.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }

    func open(_ request: URLRequest, limit: Int) async throws -> (HTTPResponseBody, HTTPURLResponse) {
        count.withLock { $0 += 1 }
        return try respond(request)
    }
}
