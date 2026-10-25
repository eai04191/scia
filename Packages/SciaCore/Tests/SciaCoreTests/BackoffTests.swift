import Testing
@testable import SciaCore

/// 送り直し、つなぎ直し、読み直しの間隔を決める決まり。
struct BackoffTests {
    @Test func doublesUpToMaximum() {
        let backoff = Backoff(initial: .seconds(5), maximum: .seconds(60))
        #expect((1...6).map { backoff.delay(afterFailures: $0) } == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60)])
    }

    @Test func doublesWithoutMaximum() {
        let backoff = Backoff(initial: .seconds(1), maximum: nil)
        #expect((1...3).map { backoff.delay(afterFailures: $0) } == [.seconds(1), .seconds(2), .seconds(4)])
    }

    /// 再開の時刻が自分の間隔より遅ければ、それまで待つ。
    @Test func waitsUntilServerSaysToResume() {
        let backoff = Backoff(initial: .seconds(1), maximum: .seconds(60))
        #expect(backoff.delay(afterFailures: 1, retryAfter: .seconds(120)) == .seconds(120))
        #expect(backoff.delay(afterFailures: 3, retryAfter: .seconds(2)) == .seconds(4))
        #expect(backoff.delay(afterFailures: 1, retryAfter: nil) == .seconds(1))
    }

    /// 揺らぎは、間隔を上下に散らす。乱数の両端で、決めた割合の端になる。
    @Test func jitterSpreadsAroundDelay() {
        func delay(random: Double) -> Duration {
            Backoff(initial: .seconds(10), maximum: nil, jitter: Jitter(spread: 0.2) { random }).delay(afterFailures: 1)
        }
        #expect(delay(random: 0) == .seconds(8))
        #expect(delay(random: 0.5) == .seconds(10))
        #expect(delay(random: 0.75) == .seconds(11))
    }

    /// サーバーが示した再開の時刻より前に試さないよう、再開までの長さは散らさない。
    @Test func jitterDoesNotShortenRetryAfter() {
        let backoff = Backoff(initial: .seconds(10), maximum: nil, jitter: Jitter(spread: 0.2) { 0 })
        #expect(backoff.delay(afterFailures: 1, retryAfter: .seconds(9)) == .seconds(9))
    }

    /// 既定の送り直しとつなぎ直しと読み直しは、揺らぎを持つ。
    @Test @MainActor func standardPoliciesHaveJitter() {
        #expect(RetryPolicy.standard.jitter.spread > 0)
        #expect(ReconnectingStream.Policy.standard.jitter.spread > 0)
        #expect(TuningCatalog.imageRetry(in: TuningStore(defaults: nil)).jitter.spread > 0)
    }
}
