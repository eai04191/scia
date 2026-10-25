import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// 読めなかった画像を、自動の読み込みでいつ読み直してよいか。
@MainActor
struct ImageRetryScheduleTests {
    private let clock = TestClock()
    private let image = URL(filePath: "/").appending(path: "system/emoji.png")

    private func makeSchedule() -> ImageRetrySchedule {
        ImageRetrySchedule(policy: { ImageRetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }, clock: clock)
    }

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    /// 待てば直る失敗は、間隔が過ぎるまで自動では読まず、過ぎたら読む。
    @Test(arguments: [
        URLError(.notConnectedToInternet) as any Error,
        RemoteFetchError(statusCode: 503),
        RemoteFetchError(statusCode: 408),
    ])
    func temporaryFailureWaitsForTheDelay(error: any Error) {
        var schedule = makeSchedule()
        schedule.recordFailure(error, for: image)

        #expect(!schedule.allowsAutomaticLoad(of: image))
        clock.advance(by: .seconds(4))
        #expect(!schedule.allowsAutomaticLoad(of: image))
        clock.advance(by: .seconds(1))
        #expect(schedule.allowsAutomaticLoad(of: image))
    }

    /// 続けて失敗するたびに間隔を倍にし、上限で止める。
    @Test func delayDoublesUpToTheLimit() {
        var schedule = makeSchedule()
        var waited: [Duration] = []
        for _ in 0..<6 {
            schedule.recordFailure(URLError(.timedOut), for: image)
            var delay = Duration.zero
            while !schedule.allowsAutomaticLoad(of: image) {
                clock.advance(by: .seconds(1))
                delay += .seconds(1)
            }
            waited.append(delay)
        }
        #expect(waited == [5, 10, 20, 40, 60, 60].map { .seconds($0) })
    }

    /// 読めたら忘れ、次の失敗は最初の間隔から数える。
    @Test func successResetsTheDelay() {
        var schedule = makeSchedule()
        schedule.recordFailure(URLError(.timedOut), for: image)
        clock.advance(by: .seconds(5))
        schedule.recordFailure(URLError(.timedOut), for: image)
        schedule.recordSuccess(for: image)
        #expect(schedule.allowsAutomaticLoad(of: image))
        #expect(!schedule.hasFailed(image))

        schedule.recordFailure(URLError(.timedOut), for: image)
        clock.advance(by: .seconds(5))
        #expect(schedule.allowsAutomaticLoad(of: image))
    }

    /// 待っても直らない失敗は、自動では読み直さない。
    @Test(arguments: [RemoteFetchError(statusCode: 404) as any Error, RemoteFetchError(statusCode: 410), CocoaError(.fileReadCorruptFile)])
    func permanentFailureIsNotRetriedAutomatically(error: any Error) {
        var schedule = makeSchedule()
        schedule.recordFailure(error, for: image)
        clock.advance(by: .seconds(3600))
        #expect(!schedule.allowsAutomaticLoad(of: image))
        #expect(schedule.hasFailed(image))
    }

    @Test(arguments: [CancellationError() as any Error, URLError(.cancelled)])
    func cancellationIsNotRecorded(error: any Error) {
        var schedule = makeSchedule()
        schedule.recordFailure(error, for: image)
        #expect(schedule.allowsAutomaticLoad(of: image))
        #expect(!schedule.hasFailed(image))
    }

    /// 応答が示した再開の時刻が間隔より遅ければ、それまで待つ。
    @Test func waitsUntilTheServerSaysToRetry() {
        var schedule = makeSchedule()
        schedule.recordFailure(RemoteFetchError(statusCode: 429, retryAfter: .seconds(120)), for: image)
        clock.advance(by: .seconds(119))
        #expect(!schedule.allowsAutomaticLoad(of: image))
        clock.advance(by: .seconds(1))
        #expect(schedule.allowsAutomaticLoad(of: image))
    }

    /// Mastodonは`/media_proxy`をまとめて制限するため、1つが429を返したら、同じサーバーの`/media_proxy`の画像も読まない。
    /// 保存し直された画像と、ほかのサーバーの`/media_proxy`は止めない。
    @Test func rateLimitedMediaProxyPausesTheWholeProxyOfTheServer() throws {
        var schedule = makeSchedule()
        schedule.recordFailure(RemoteFetchError(statusCode: 429, retryAfter: .seconds(300)), for: try url("https://example.social/media_proxy/1/original"))

        #expect(!schedule.allowsAutomaticLoad(of: try url("https://example.social/media_proxy/2/small")))
        #expect(schedule.allowsAutomaticLoad(of: try url("https://example.social/system/media_attachments/files/3/small/a.png")))
        #expect(schedule.allowsAutomaticLoad(of: try url("https://other.example/media_proxy/2/small")))

        clock.advance(by: .seconds(300))
        #expect(schedule.allowsAutomaticLoad(of: try url("https://example.social/media_proxy/2/small")))
    }

    /// 再開の時刻のない失敗では、ほかのURLを止めない。
    @Test func failureWithoutResetTimeDoesNotPauseOthers() throws {
        var schedule = makeSchedule()
        schedule.recordFailure(RemoteFetchError(statusCode: 503), for: try url("https://example.social/media_proxy/1/original"))
        #expect(schedule.allowsAutomaticLoad(of: try url("https://example.social/media_proxy/2/small")))
    }
}
