import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct SlowActivityTests {
    private static let delay = Duration.milliseconds(300)

    private func makeActivity(_ clock: TestClock) -> (SlowActivity, changes: () -> [Bool]) {
        let activity = SlowActivity(clock: clock) { Self.delay }
        var changes: [Bool] = []
        activity.onSlowChange = { changes.append($0) }
        return (activity, { changes })
    }

    /// 待つ時間より長引いたら知らせ、終わったら戻す。
    @Test func becomesSlowAfterDelayAndClearsWhenDone() async throws {
        let clock = TestClock()
        let (activity, changes) = makeActivity(clock)
        let gate = Gate()

        let waiting = Task { try await activity.track { try await gate.wait() } }
        try await waitUntil { gate.waiterCount >= 1 && clock.sleeperCount(remaining: Self.delay) >= 1 }
        clock.advance(by: Self.delay - .milliseconds(1))
        #expect(!activity.isSlow)

        clock.advance(by: .milliseconds(1))
        try await waitUntil { activity.isSlow }

        gate.open()
        try await waiting.value
        #expect(!activity.isSlow)
        #expect(changes() == [true, false])
    }

    /// 待つ時間より前に終わったら知らせず、待つ処理も残さない。
    @Test func staysQuietWhenDoneBeforeDelay() async throws {
        let clock = TestClock()
        let (activity, changes) = makeActivity(clock)

        await activity.track {}

        #expect(activity.waitingCount == 0)
        try await waitUntil { clock.sleeperCount(dueWithin: Self.delay) == 0 }
        #expect(changes().isEmpty)
    }

    /// 長引いた操作が残っている間は、ほかの操作が終わっても知らせたままにする。投げて終わった操作も数えるのをやめる。
    @Test func staysSlowWhileAnotherSlowOperationRemains() async throws {
        struct Failure: Error {}
        let clock = TestClock()
        let (activity, changes) = makeActivity(clock)
        let first = Gate()
        let second = Gate()

        let firstWaiting = Task { try await activity.track { try await first.wait() } }
        let secondWaiting = Task {
            try await activity.track {
                try await second.wait()
                throw Failure()
            }
        }
        try await waitUntil { first.waiterCount >= 1 && second.waiterCount >= 1 && clock.sleeperCount(remaining: Self.delay) >= 2 }
        clock.advance(by: Self.delay)
        try await waitUntil { activity.isSlow }

        first.open()
        try await firstWaiting.value
        #expect(activity.isSlow)

        second.open()
        await #expect(throws: Failure.self) { try await secondWaiting.value }
        #expect(!activity.isSlow)
        #expect(changes() == [true, false])
    }

    /// 取り消された操作は、長引いていても数えるのをやめる。
    @Test func cancelledOperationStopsCounting() async throws {
        let clock = TestClock()
        let (activity, _) = makeActivity(clock)
        let gate = Gate()

        let waiting = Task { try await activity.track { try await gate.wait() } }
        try await waitUntil { gate.waiterCount >= 1 && clock.sleeperCount(remaining: Self.delay) >= 1 }
        clock.advance(by: Self.delay)
        try await waitUntil { activity.isSlow }

        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(!activity.isSlow)
        #expect(activity.waitingCount == 0)
    }
}
