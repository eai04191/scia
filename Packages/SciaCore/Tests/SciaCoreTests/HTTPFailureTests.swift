import Foundation
import Testing
@testable import SciaCore

/// どの経路も、送り直すか、待つか、あきらめるかを、この分け方だけで決める。
struct HTTPFailureTests {
    @Test(arguments: [408, 429, 500, 502, 503, 504])
    func temporaryStatusWaits(statusCode: Int) {
        #expect(HTTPFailure(HTTPStatusError(statusCode: statusCode, retryAfter: .seconds(30))) == .temporary(retryAfter: .seconds(30)))
    }

    @Test(arguments: [400, 403, 404, 410, 422])
    func otherClientErrorsArePermanent(statusCode: Int) {
        #expect(HTTPFailure(HTTPStatusError(statusCode: statusCode)) == .permanent)
    }

    @Test func unauthorizedIsSeparated() {
        #expect(HTTPFailure(HTTPStatusError(statusCode: 401)) == .unauthorized)
        #expect(HTTPFailure(MastodonAPIError(statusCode: 401, message: "")) == .unauthorized)
    }

    /// REST APIのエラーも、同じ分け方で、示された再開までの長さを持つ。
    @Test func apiErrorCarriesRetryAfter() {
        #expect(HTTPFailure(MastodonAPIError(statusCode: 429, message: "", retryAfter: .seconds(120))) == .temporary(retryAfter: .seconds(120)))
    }

    @Test func networkFailureIsTemporary() {
        #expect(HTTPFailure(URLError(.notConnectedToInternet)) == .temporary(retryAfter: nil))
    }

    /// 自動の通信を控えている間に送ろうとした失敗は、再開まで待てば通る。
    @Test func pausedAutomaticRequestWaitsUntilResume() {
        let paused = AutomaticRequestsPaused(until: Date(timeIntervalSince1970: 1_800_000_000), retryAfter: .seconds(45))
        #expect(HTTPFailure(paused) == .temporary(retryAfter: .seconds(45)))
    }

    @Test func tooLargeResponseIsPermanent() {
        #expect(HTTPFailure(ResponseTooLarge(limit: 1)) == .permanent)
    }

    @Test(arguments: [CancellationError() as any Error, URLError(.cancelled)])
    func cancellationIsNotFailure(error: any Error) {
        #expect(HTTPFailure(error) == nil)
    }
}
