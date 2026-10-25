import Foundation
import Testing
@testable import SciaCore

/// 画像を読むときは、2xx以外の応答の本文を画像として渡さない。
struct RemoteFetchTests {
    private func url() throws -> URL {
        try #require(URL(string: "https://example.social/system/emoji.png"))
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fetch(_ response: StubTransport.Response) -> RemoteFetch {
        let now = now
        return RemoteFetch(transport: StubTransport([response]), now: { now })
    }

    @Test func returnsBodyOfSuccessfulResponse() async throws {
        let body = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(try await fetch(StubTransport.Response(statusCode: 200, body: body)).data(from: try url()) == body)
    }

    /// サーバーの障害のページは、画像として読めないデータではなく、応答の失敗として返す。
    @Test(arguments: [404, 503])
    func errorPageIsNotReturnedAsData(statusCode: Int) async throws {
        let error = await #expect(throws: HTTPStatusError.self) {
            try await fetch(.json("<html>\(statusCode)</html>", statusCode: statusCode)).data(from: try url())
        }
        #expect(error == HTTPStatusError(statusCode: statusCode))
    }

    /// Mastodonが`/media_proxy`を制限したときの429は、`X-RateLimit-Reset`で再開の時刻を示す。
    @Test func readsResetTimeOfRateLimit() async throws {
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(120))
        let error = await #expect(throws: HTTPStatusError.self) {
            try await fetch(.json(#"{"error":"Too many requests"}"#, statusCode: 429, headers: ["X-RateLimit-Reset": reset])).data(from: try url())
        }
        #expect(error == HTTPStatusError(statusCode: 429, retryAfter: .seconds(120)))
    }

    @Test func readsRetryAfter() async throws {
        let error = await #expect(throws: HTTPStatusError.self) {
            try await fetch(.json("", statusCode: 503, headers: ["Retry-After": "30"])).data(from: try url())
        }
        #expect(error == HTTPStatusError(statusCode: 503, retryAfter: .seconds(30)))
    }

    @Test func passesThroughNetworkFailure() async throws {
        await #expect(throws: URLError(.notConnectedToInternet)) {
            try await fetch(.failure(.notConnectedToInternet)).data(from: try url())
        }
    }

    /// デバッグのダミー投稿と部品カタログが渡す`data:`のURLは、HTTPの応答がないのでそのまま読む。
    @Test func readsDataURLWithoutTransport() async throws {
        let url = try #require(URL(string: "data:image/png;base64,iVBORw=="))
        #expect(try await RemoteFetch(transport: StubTransport([])).data(from: url) == Data(base64Encoded: "iVBORw=="))
    }
}
