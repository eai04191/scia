import Foundation
import Synchronization
import Testing
@testable import SciaCore

struct RateLimitTests {
    /// 2027-01-15T08:00:00Z
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeClient(_ transport: StubTransport, gate: RateLimitGate) throws -> MastodonClient {
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
            rateLimit: gate
        )
    }

    private func response(_ headers: [String: String]) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://example.social"))
        return try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: headers))
    }

    // MARK: - 再開の時刻

    @Test func resumeDateReadsRetryAfterSeconds() throws {
        #expect(RateLimitGate.resumeDate(of: try response(["Retry-After": "120"]), now: Self.now) == Self.now.addingTimeInterval(120))
    }

    @Test func resumeDateReadsRetryAfterHTTPDate() throws {
        let date = RateLimitGate.resumeDate(of: try response(["Retry-After": "Fri, 15 Jan 2027 08:00:00 GMT"]), now: Self.now)
        #expect(date == Self.now)
    }

    /// Mastodonは429にX-RateLimit-Resetを付ける。
    @Test func resumeDateReadsRateLimitReset() throws {
        let date = RateLimitGate.resumeDate(of: try response(["X-RateLimit-Reset": "2027-01-15T08:05:00.000Z"]), now: Self.now)
        #expect(date == Self.now.addingTimeInterval(300))
    }

    @Test func resumeDateIsNilWithoutHeaders() throws {
        #expect(RateLimitGate.resumeDate(of: try response([:]), now: Self.now) == nil)
        #expect(RateLimitGate.resumeDate(of: try response(["Retry-After": "そのうち"]), now: Self.now) == nil)
    }

    // MARK: - 自動の通信を止める

    @Test func rateLimitedResponsePausesOnlyAutomaticRequests() async throws {
        let gate = RateLimitGate(now: { Self.now })
        let transport = StubTransport([
            .json(#"{"error":"Too many requests"}"#, statusCode: 429, headers: ["X-RateLimit-Reset": "2027-01-15T08:05:00.000Z"]),
            try .fixture("home_timeline"),
        ])
        let client = try makeClient(transport, gate: gate)

        await #expect(throws: MastodonAPIError.self) { try await client.homeTimeline(TimelineQuery(limit: 40)) }
        let paused = await #expect(throws: AutomaticRequestsPaused.self) {
            try await RequestOrigin.$current.withValue(.automatic) { try await client.homeTimeline(TimelineQuery(limit: 40)) }
        }
        #expect(paused?.until == Self.now.addingTimeInterval(300))
        // 使う人の操作は止めない。
        _ = try await client.homeTimeline(TimelineQuery(limit: 40))
        #expect(await transport.requests.count == 2)
    }

    @Test func unavailableWithRetryAfterPausesAutomaticRequests() async throws {
        let gate = RateLimitGate(now: { Self.now })
        let transport = StubTransport([.json("<html>503</html>", statusCode: 503, headers: ["Retry-After": "30"])])
        let client = try makeClient(transport, gate: gate)

        await #expect(throws: MastodonAPIError.self) {
            try await RequestOrigin.$current.withValue(.automatic) { try await client.homeTimeline(TimelineQuery(limit: 40)) }
        }

        #expect(await gate.pausedUntil == Self.now.addingTimeInterval(30))
    }

    /// 時刻が分からなければ止めない。いつまで止めればよいか分からないため。
    @Test func rateLimitWithoutResumeDateDoesNotPause() async throws {
        let gate = RateLimitGate(now: { Self.now })
        let transport = StubTransport([.json(#"{"error":"Too many requests"}"#, statusCode: 429)])

        await #expect(throws: MastodonAPIError.self) { try await makeClient(transport, gate: gate).homeTimeline(TimelineQuery(limit: 40)) }

        #expect(await gate.pausedUntil == nil)
    }

    @Test func automaticRequestsResumeAfterResumeDate() async throws {
        let clock = TestClock(Self.now)
        let gate = RateLimitGate(now: { clock.now })
        await gate.pause(until: Self.now.addingTimeInterval(60))
        let transport = StubTransport([try .fixture("home_timeline")])
        let client = try makeClient(transport, gate: gate)

        clock.now = Self.now.addingTimeInterval(61)

        _ = try await RequestOrigin.$current.withValue(.automatic) { try await client.homeTimeline(TimelineQuery(limit: 40)) }
    }

    /// 止めた時刻が過ぎたら、失敗していた読み込みをやり直せるよう知らせる。
    @Test func gateAnnouncesResumption() async throws {
        let gate = RateLimitGate()
        await gate.pause(until: Date().addingTimeInterval(0.05))

        var iterator = gate.resumptions.makeAsyncIterator()
        let resumed: Void? = await iterator.next()

        #expect(resumed != nil)
        #expect(await gate.pausedUntil == nil)
    }

    /// 過ぎた時刻（`Retry-After: 0`や、時計のずれた`X-RateLimit-Reset`）では止めない。
    /// 止めるとすぐ再開を知らせ、読み込み直しが同じ応答を受けて、送り直しの上限を超えて繰り返すため。
    @Test(arguments: [["Retry-After": "0"], ["X-RateLimit-Reset": "2027-01-15T07:59:00.000Z"]])
    func pastResumeDateDoesNotPause(headers: [String: String]) async throws {
        let gate = RateLimitGate(now: { Self.now })

        #expect(await gate.pause(respondingTo: try response(headers)) == false)
        #expect(await gate.pausedUntil == nil)
    }

    /// 止めている間に別の応答でもっと先まで止められたら、先の時刻まで待つ。
    @Test func laterPauseExtendsEarlierPause() async {
        let gate = RateLimitGate(now: { Self.now })
        await gate.pause(until: Self.now.addingTimeInterval(60))
        await gate.pause(until: Self.now.addingTimeInterval(30))
        #expect(await gate.pausedUntil == Self.now.addingTimeInterval(60))
        await gate.pause(until: Self.now.addingTimeInterval(90))
        #expect(await gate.pausedUntil == Self.now.addingTimeInterval(90))
    }
}

/// テストから進められる時計。
private final class TestClock: Sendable {
    private let value: Mutex<Date>

    init(_ now: Date) {
        value = Mutex(now)
    }

    var now: Date {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
