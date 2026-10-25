import Foundation
import Synchronization
import Testing
@testable import SciaCore

struct MediaUploadTests {
    private func makeClient(_ transport: StubTransport) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport
        )
    }

    private let upload = MediaUpload(data: Data([0xFF, 0xD8, 0xFF]), filename: "IMG_0001.jpg", mimeType: "image/jpeg", description: "窓辺の猫")

    /// 眠ると、眠った分だけすぐに進む時計。
    private final class ManualClock: Clock, Sendable {
        struct Instant: InstantProtocol {
            var offset: Duration

            func advanced(by duration: Duration) -> Self { Self(offset: offset + duration) }
            func duration(to other: Self) -> Duration { other.offset - offset }
            static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
        }

        private let state = Mutex((now: Instant(offset: .zero), sleeps: [Duration]()))

        var now: Instant { state.withLock { $0.now } }
        var minimumResolution: Duration { .zero }
        var sleeps: [Duration] { state.withLock { $0.sleeps } }

        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            state.withLock { state in
                state.sleeps.append(state.now.duration(to: deadline))
                state.now = max(state.now, deadline)
            }
        }
    }

    @Test func uploadSendsMultipartFileAndDescription() async throws {
        let transport = StubTransport([try .fixture("media_attachment")])

        let attachment = try await makeClient(transport).uploadMedia(upload)

        #expect(attachment.id == "113000000000000100")
        #expect(attachment.url != nil)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v2/media")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.split(separator: "boundary=").last.map(String.init))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let expected = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"IMG_0001.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
            + Data([0xFF, 0xD8, 0xFF])
            + Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"description\"\r\n\r\n窓辺の猫\r\n--\(boundary)--\r\n".utf8)
        #expect(request.httpBody == expected)
    }

    /// 送った割合を知らせる口が、`MastodonClient`を通って通信の部品まで届く。
    @Test func uploadProgressReachesTransport() async throws {
        struct ReportingTransport: HTTPTransport {
            let base: StubTransport

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                UploadProgress.report?(0.5)
                UploadProgress.report?(1)
                return try await base.send(request)
            }
        }
        let client = MastodonClient(
            credential: try makeClient(StubTransport([])).credential,
            transport: ReportingTransport(base: StubTransport([try .fixture("media_attachment")]))
        )
        let received = Mutex([Double]())
        _ = try await UploadProgress.$report.withValue({ fraction in received.withLock { $0.append(fraction) } }) {
            try await client.uploadMedia(upload)
        }
        #expect(received.withLock { $0 } == [0.5, 1])
    }

    @Test func uploadOmitsEmptyDescription() async throws {
        let transport = StubTransport([try .fixture("media_attachment")])

        _ = try await makeClient(transport).uploadMedia(MediaUpload(data: Data([0x00]), filename: "a.png", mimeType: "image/png"))

        let body = String(decoding: try #require(await transport.requests.first?.httpBody), as: UTF8.self)
        #expect(!body.contains("name=\"description\""))
    }

    @Test func acceptedUploadHasNoURLUntilProcessed() async throws {
        let transport = StubTransport([try .fixture("media_attachment_processing", statusCode: 202)])

        let attachment = try await makeClient(transport).uploadMedia(upload)

        #expect(attachment.id == "113000000000000101")
        #expect(attachment.url == nil)
        #expect(attachment.type == .video)
    }

    @Test(arguments: [413, 422])
    func refusedFileIsRejected(statusCode: Int) async throws {
        let transport = StubTransport([.json(#"{"error":"Validation failed: File content type is invalid, File is invalid"}"#, statusCode: statusCode)])

        await #expect(throws: MediaUploadError.rejected(MastodonAPIError(statusCode: statusCode, message: "Validation failed: File content type is invalid, File is invalid", serverMessage: "Validation failed: File content type is invalid, File is invalid"))) {
            _ = try await makeClient(transport).uploadMedia(upload)
        }
    }

    @Test func proxyErrorPageIsNotShown() async throws {
        let html = "<html><head><title>413 Request Entity Too Large</title></head><body>nginx</body></html>"
        let transport = StubTransport([StubTransport.Response(statusCode: 413, body: Data(html.utf8))])

        let error = await #expect(throws: MediaUploadError.self) {
            _ = try await makeClient(transport).uploadMedia(upload)
        }
        #expect(error?.errorDescription == "サーバーがメディアを受け付けませんでした。")
    }

    @Test func serverErrorOnUploadIsProcessingFailure() async throws {
        let transport = StubTransport([.json(#"{"error":"Error processing thumbnail for uploaded media"}"#, statusCode: 500)])

        await #expect(throws: MediaUploadError.processingFailed(MastodonAPIError(statusCode: 500, message: "Error processing thumbnail for uploaded media", serverMessage: "Error processing thumbnail for uploaded media"))) {
            _ = try await makeClient(transport).uploadMedia(upload)
        }
    }

    @Test func unauthorizedUploadStaysAPIError() async throws {
        let transport = StubTransport([.json(#"{"error":"The access token is invalid"}"#, statusCode: 401)])

        let error = await #expect(throws: MastodonAPIError.self) {
            _ = try await makeClient(transport).uploadMedia(upload)
        }
        #expect(error?.isUnauthorized == true)
    }

    @Test func waitPollsUntilURLIsSet() async throws {
        let transport = StubTransport([
            .json("", statusCode: 206),
            try .fixture("media_attachment_processing"),
            try .fixture("media_attachment"),
        ])
        let clock = ManualClock()

        let attachment = try await makeClient(transport).waitUntilProcessed("113000000000000100", clock: clock)

        #expect(attachment.url != nil)
        #expect(clock.sleeps == [.seconds(1), .seconds(1)])
        let paths = await transport.requests.map { $0.url?.path() }
        #expect(paths == Array(repeating: "/api/v1/media/113000000000000100", count: 3))
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func processingFailureWhileWaiting() async throws {
        let transport = StubTransport([
            .json("", statusCode: 206),
            .json(#"{"error":"Error processing thumbnail for uploaded media"}"#, statusCode: 422),
        ])

        await #expect(throws: MediaUploadError.processingFailed(MastodonAPIError(statusCode: 422, message: "Error processing thumbnail for uploaded media", serverMessage: "Error processing thumbnail for uploaded media"))) {
            _ = try await makeClient(transport).waitUntilProcessed("113000000000000101", clock: ManualClock())
        }
    }

    @Test func waitLengthensIntervalLikeWebUI() async throws {
        // Mastodonのweb UIと同じく、n回目の問い合わせのあとは、log2(n)秒（1秒未満なら1秒）おく。
        let transport = StubTransport(Array(repeating: .json("", statusCode: 206), count: 4) + [try .fixture("media_attachment")])
        let clock = ManualClock()

        _ = try await makeClient(transport).waitUntilProcessed("113000000000000101", clock: clock)

        #expect(clock.sleeps == [.seconds(1), .seconds(1), .seconds(log2(3.0)), .seconds(2)])
    }

    @Test func waitKeepsPollingWithoutTimeLimit() async throws {
        // 長い動画や混んだサーバーでは、変換に数分かかる。何分かかっても諦めず、終わるまで待つ。
        let transport = StubTransport(Array(repeating: .json("", statusCode: 206), count: 150) + [try .fixture("media_attachment")])
        let clock = ManualClock()

        let attachment = try await makeClient(transport).waitUntilProcessed("113000000000000101", clock: clock)

        #expect(attachment.url != nil)
        #expect(clock.sleeps.reduce(.zero, +) > .seconds(10 * 60))
    }

    @Test func updateDescriptionSendsPutForm() async throws {
        let transport = StubTransport([try .fixture("media_attachment")])

        let attachment = try await makeClient(transport).updateMediaDescription("113000000000000100", description: "窓辺の猫 & 鉢植え")

        #expect(attachment.description == "窓辺の猫")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/api/v1/media/113000000000000100")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(components.queryItems == [URLQueryItem(name: "description", value: "窓辺の猫 & 鉢植え")])
    }
}
