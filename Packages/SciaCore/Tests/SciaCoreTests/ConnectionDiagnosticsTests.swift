import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct ConnectionDiagnosticsTests {
    private func makeMediaFormats() throws -> UnprocessableMediaFormats {
        let defaults = TestScratch.defaults("ConnectionDiagnosticsTests")
        return UnprocessableMediaFormats(defaults: defaults, instance: try #require(URL(string: "https://example.social")))
    }

    @Test func statusGathersSessionState() async throws {
        let clock = TestClock()
        let rateLimit = RateLimitGate(now: { clock.date }, clock: clock)
        let features = FeatureAvailability()
        let requestLog = RequestLog(includesBody: false)
        let diagnostics = ConnectionDiagnostics(rateLimit: rateLimit, features: features, requestLog: requestLog, mediaFormats: try makeMediaFormats())
        let until = clock.date.addingTimeInterval(600)
        await rateLimit.pause(until: until)
        await features.disable(.markers, statusCode: 404)
        requestLog.record(URLRequest(url: try #require(URL(string: "https://example.social/api/v1/timelines/home"))), statusCode: 502, error: MastodonAPIError(statusCode: 502, message: ""), body: nil)
        let droppedBefore = DecodingLog.droppedCount
        DecodingLog.dropped(Status.self, at: [], URLError(.unknown))

        let status = await diagnostics.status()

        #expect(status.pausedUntil == until)
        #expect(status.disabledFeatures.map(\.feature) == [.markers])
        #expect(status.recentFailures.map(\.logMessage) == ["GET /api/v1/timelines/home HTTP 502"])
        // 数はプロセス全体で数えるため、並行して走る他のテストでも増える。
        #expect(status.droppedCount >= droppedBefore + 1)
    }

    @Test func keepsStreamingStateAndSubscriptions() throws {
        let diagnostics = ConnectionDiagnostics(rateLimit: RateLimitGate(), features: FeatureAvailability(), requestLog: RequestLog(includesBody: false), mediaFormats: try makeMediaFormats())

        diagnostics.setStreaming(.polling, subscriptions: [.user])

        #expect(diagnostics.streaming == .polling)
        #expect(diagnostics.streamingSubscriptions == [.user])
    }
}
