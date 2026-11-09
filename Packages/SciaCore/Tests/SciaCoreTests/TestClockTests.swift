import SciaTesting
import Testing

@Suite struct TestClockTests {
    private func startSleeping(_ duration: Duration, on clock: TestClock) -> Task<Void, any Error> {
        Task { try await clock.sleep(for: duration) }
    }

    @Test func countsOnlySleepersWithThatRemainingDuration() async throws {
        let clock = TestClock()
        let short = startSleeping(.milliseconds(50), on: clock)
        let long = startSleeping(.milliseconds(600), on: clock)
        try await waitUntil { clock.sleeperCount(remaining: .milliseconds(50)) >= 1 && clock.sleeperCount(remaining: .milliseconds(600)) >= 1 }

        #expect(clock.sleeperCount(remaining: .milliseconds(50)) == 1)
        #expect(clock.sleeperCount(remaining: .milliseconds(600)) == 1)
        #expect(clock.sleeperCount(remaining: .milliseconds(100)) == 0)

        clock.advance(by: .milliseconds(100))
        #expect(clock.sleeperCount(remaining: .milliseconds(500)) == 1)
        long.cancel()
        try await short.value
    }

    /// 長さの違う待ちが先に眠っていても、その長さの待ちが眠り始めるまで時計を進めない。進めてしまうと、あとから眠り始めた待ちは起こされない。
    @Test func waitsForSleeperThatStartsLater() async throws {
        let clock = TestClock()
        let unrelated = startSleeping(.milliseconds(50), on: clock)
        try await waitUntil { clock.sleeperCount >= 1 }

        let advancing = Task { try await clock.advance(afterSleeping: .milliseconds(600)) }
        let target = startSleeping(.milliseconds(600), on: clock)

        try await advancing.value
        try await target.value
        try await unrelated.value
        #expect(clock.now.offset == .milliseconds(600))
    }

    @Test func advancesByGivenAmountAfterSleeperStarts() async throws {
        let clock = TestClock()
        let target = startSleeping(.milliseconds(500), on: clock)

        try await clock.advance(by: .milliseconds(499), afterSleeping: .milliseconds(500))

        #expect(clock.now.offset == .milliseconds(499))
        #expect(clock.sleeperCount(remaining: .milliseconds(1)) == 1)
        clock.advance(by: .milliseconds(1))
        try await target.value
    }

    @Test func waitsForRequestedNumberOfSleepers() async throws {
        let clock = TestClock()
        let sleepers = (0..<2).map { _ in startSleeping(.seconds(5), on: clock) }

        try await clock.advance(afterSleeping: .seconds(5), count: 2)

        for sleeper in sleepers { try await sleeper.value }
        #expect(clock.sleeperCount == 0)
    }
}
