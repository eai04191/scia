import Foundation
import Testing
@testable import SciaCore

/// リリース版の記録だけで原因を絞れるようにする。応答の本文は個人情報を含みうるため、デバッグ版でだけ足す。
struct RequestLogTests {
    private func makeClient(_ transport: StubTransport, log: RequestLog) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport,
            retry: RetryPolicy(maxRetries: 1, initialDelay: .zero),
            requestLog: log
        )
    }

    @Test(arguments: [
        ("/api/v1/statuses/113000000000000001/favourite", "/api/v1/statuses/:id/favourite"),
        ("/api/v2/instance", "/api/v2/instance"),
        ("/api/v1/accounts/01HXYZABCDEF0123456789/statuses", "/api/v1/accounts/:id/statuses"),
        ("/api/v1/timelines/home", "/api/v1/timelines/home"),
    ])
    func pathHidesIDs(path: String, expected: String) throws {
        #expect(RequestLog.redactedPath(try #require(URL(string: "https://example.social\(path)?max_id=1&acct=alice"))) == expected)
    }

    @Test func serverErrorIsRecordedWithoutBodyInRelease() async throws {
        let log = RequestLog(includesBody: false)
        let transport = StubTransport([.json(#"{"error":"alice@example.social is secret"}"#, statusCode: 500)])

        await #expect(throws: MastodonAPIError.self) { try await makeClient(transport, log: log).favourite("113000000000000001") }

        let failure = try #require(log.recentFailures.first)
        #expect(failure.method == "POST")
        #expect(failure.path == "/api/v1/statuses/:id/favourite")
        #expect(failure.statusCode == 500)
        #expect(failure.kind == .status)
        #expect(failure.body == nil)
        #expect(failure.logMessage == "POST /api/v1/statuses/:id/favourite HTTP 500")
        #expect(!failure.logMessage.contains("alice"))
    }

    @Test func debugBuildAddsBody() async throws {
        let log = RequestLog(includesBody: true)
        let transport = StubTransport([.json("<html>nginx</html>", statusCode: 404)])

        await #expect(throws: MastodonAPIError.self) { try await makeClient(transport, log: log).account("1") }

        let failure = try #require(log.recentFailures.first)
        #expect(failure.body == "<html>nginx</html>")
        #expect(failure.logMessage == "GET /api/v1/accounts/:id HTTP 404 body=<html>nginx</html>")
    }

    /// 読めなかった応答は、どの項目にどんな形の値があったかを残し、値そのものは残さない。
    @Test func decodingFailureRecordsPathAndShapeOnly() async throws {
        let log = RequestLog(includesBody: false)
        let transport = StubTransport([.json(#"{"id":12345,"username":"alice-secret"}"#, statusCode: 200)])

        await #expect(throws: DecodingError.self) { try await makeClient(transport, log: log).account("1") }

        let failure = try #require(log.recentFailures.first)
        #expect(failure.statusCode == 200)
        #expect(failure.kind == .decoding("typeMismatch(String) at .id found number"))
        #expect(!failure.logMessage.contains("12345"))
        #expect(!failure.logMessage.contains("alice-secret"))
    }

    @Test func networkFailureRecordsCode() async throws {
        let log = RequestLog(includesBody: false)
        let transport = StubTransport([.failure(.notConnectedToInternet), .failure(.notConnectedToInternet)])

        await #expect(throws: URLError.self) { try await makeClient(transport, log: log).homeTimeline(TimelineQuery(limit: 40)) }

        // 送り直した分は残さず、最後の失敗だけを残す。
        #expect(log.recentFailures.map(\.logMessage) == ["GET /api/v1/timelines/home URLError -1009"])
    }

    /// ログに書く失敗は、応答の本文やサーバーが返した文言を含めない。
    @Test func errorDescriptionForLogsOmitsResponseContent() throws {
        let apiError = MastodonAPIError.from(statusCode: 422, body: Data(#"{"error":"alice@example.social は使えません"}"#.utf8))
        #expect(SciaLog.describe(apiError) == "HTTP 422")
        #expect(SciaLog.describe(URLError(.notConnectedToInternet)) == "URLError -1009")
        let decodingError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "ISO 8601形式ではない日時です: secret"))
        #expect(!SciaLog.describe(decodingError).contains("secret"))
        #expect(SciaLog.describe(FeatureUnavailable(feature: .markers)) == "FeatureUnavailable")
    }

    /// ファイルやOSのフレームワークの失敗は、パスや説明の文を含めず、種類とコードだけを書く。
    @Test func errorDescriptionForLogsOmitsFilePaths() {
        let path = "/private/var/mobile/Documents/alice.png"
        let cocoaError = CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        #expect(SciaLog.describe(cocoaError) == "CocoaError 4")
        let nsError = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSLocalizedDescriptionKey: path])
        #expect(SciaLog.describe(nsError) == "AVFoundationErrorDomain -11800")
    }

    /// ログに残すURLは、ユーザーやIDを含むパスとクエリを落とし、ホストだけにする。
    @Test func urlForLogsKeepsOnlyHost() throws {
        let url = try #require(URL(string: "https://files.example.social/accounts/avatars/alice.png?token=secret"))
        #expect(SciaLog.host(of: url) == "files.example.social")
        #expect(SciaLog.host(of: nil) == "nil")
    }

    /// `convertFromSnakeCase`で読んだ項目も、応答のJSONのキーで探して形を書く。
    @Test func shapeFollowsSnakeCaseKeys() throws {
        let data = Data(#"{"account":{"display_name":1}}"#.utf8)
        let path: [any CodingKey] = [AnyKey("account"), AnyKey("displayName")]

        #expect(DecodingLog.shape(in: data, at: path) == "number")
    }

    /// 一覧の中の読めなかった要素も、どのAPIの応答の、どの項目にどんな形の値があったかを書く。
    @Test func droppedElementMessageIncludesRequestAndShape() throws {
        let data = Data(#"[{"id":"1","created_at":12345}]"#.utf8)
        let error = DecodingError.typeMismatch(String.self, .init(codingPath: [AnyKey(index: 0), AnyKey("createdAt")], debugDescription: "12345"))
        let context = DecodingLog.Context(request: "GET /api/v1/timelines/home", data: data)

        let message = DecodingLog.message(dropping: Status.self, at: [AnyKey(index: 0)], error, context: context)

        #expect(message == "dropped Status at [0]: typeMismatch(String) at [0].createdAt found number request=GET /api/v1/timelines/home")
    }

    @Test func keepsNewestFailuresFirst() async throws {
        let log = RequestLog(includesBody: false, capacity: 2)
        let transport = StubTransport([
            .json("x", statusCode: 400),
            .json("x", statusCode: 403),
            .json("x", statusCode: 422),
        ])
        let client = try makeClient(transport, log: log)

        for _ in 0..<3 {
            await #expect(throws: MastodonAPIError.self) { try await client.homeTimeline(TimelineQuery(limit: 40)) }
        }

        #expect(log.recentFailures.map(\.statusCode) == [422, 403])
    }
}

private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init(index: Int) {
        stringValue = "Index \(index)"
        intValue = index
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.init(index: intValue)
    }
}
