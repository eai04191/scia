import SciaTesting
import Testing
@testable import SciaCore

@MainActor
struct LatestLookupTests {
    /// 届いた結果を順に記録し、結果を使う先がまだあるかを持つ。
    @MainActor
    private final class Recorder {
        var results: [Result<String, any Error>] = []
        var values: [String] { results.compactMap { try? $0.get() } }
        var wanted = true
    }

    private struct Failure: Error, Equatable {}

    private static func work(_ value: String, after gate: Gate) -> @Sendable () async throws -> String {
        { try await gate.wait(); return value }
    }

    /// 同じメンションを2回タップしたときなど。前の要求は止め、後から始めたものの結果だけを渡す。
    @Test func laterStartSupersedesEarlier() async throws {
        let lookup = LatestLookup(clock: TestClock(), slowAfter: { .seconds(1) })
        let recorder = Recorder()
        let first = Gate()
        let second = Gate()

        lookup.start(Self.work("first", after: first), isStillWanted: { true }) { recorder.results.append($0) }
        try await waitUntil { first.waiterCount == 1 }
        lookup.start(Self.work("second", after: second), isStillWanted: { true }) { recorder.results.append($0) }
        // 前の要求は止めるので、門で待つのをやめる。
        try await waitUntil { first.waiterCount == 0 && second.waiterCount == 1 }
        first.open()
        second.open()
        try await waitUntil { !lookup.isWaiting }

        #expect(recorder.values == ["second"])
        #expect(recorder.results.count == 1)
    }

    /// 後から始めたものが先に届いても、前のものの結果はあとから渡さない。
    @Test func earlierResultArrivingLaterIsDropped() async throws {
        let lookup = LatestLookup(clock: TestClock(), slowAfter: { .seconds(1) })
        let recorder = Recorder()
        let second = Gate()
        // 前の要求は、止められても気づかずに結果を返す。
        let first: @Sendable () async throws -> String = { "first" }

        lookup.start(first, isStillWanted: { true }) { recorder.results.append($0) }
        lookup.start(Self.work("second", after: second), isStillWanted: { true }) { recorder.results.append($0) }
        second.open()
        try await waitUntil { !lookup.isWaiting }

        #expect(recorder.values == ["second"])
    }

    /// 待つ間にタブを移ったときなど、届いたときに開く先がもうなければ、結果も失敗も渡さない。
    @Test func dropsResultWhenNoLongerWanted() async throws {
        let lookup = LatestLookup(clock: TestClock(), slowAfter: { .seconds(1) })
        let recorder = Recorder()
        let gate = Gate()

        lookup.start(Self.work("profile", after: gate), isStillWanted: { recorder.wanted }) { recorder.results.append($0) }
        try await waitUntil { gate.waiterCount == 1 }
        recorder.wanted = false
        gate.open()
        try await waitUntil { !lookup.isWaiting }

        #expect(recorder.results.isEmpty)
    }

    @Test func deliversFailureWhenStillWanted() async throws {
        let lookup = LatestLookup(clock: TestClock(), slowAfter: { .seconds(1) })
        let recorder = Recorder()

        lookup.start({ throw Failure() }, isStillWanted: { true }) { recorder.results.append($0) }
        try await waitUntil { !lookup.isWaiting }

        #expect(recorder.results.count == 1)
        #expect(throws: Failure.self) { try recorder.results.first?.get() }
    }

    /// 遅いときだけ知らせる。すぐ届いたときに、チップが一瞬だけ出入りしないようにする。
    @Test func reportsSlowOnlyAfterDelay() async throws {
        let clock = TestClock()
        let lookup = LatestLookup(clock: clock, slowAfter: { .seconds(1) })
        var changes: [Bool] = []
        lookup.onSlowChange = { changes.append($0) }
        let gate = Gate()

        lookup.start(Self.work("profile", after: gate), isStillWanted: { true }) { _ in }
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .milliseconds(999))
        #expect(!lookup.isSlow)
        clock.advance(by: .milliseconds(1))
        try await waitUntil { lookup.isSlow }
        gate.open()
        try await waitUntil { !lookup.isWaiting }

        #expect(changes == [true, false])
        #expect(!lookup.isSlow)
    }

    @Test func fastResultNeverReportsSlow() async throws {
        let clock = TestClock()
        let lookup = LatestLookup(clock: clock, slowAfter: { .seconds(1) })
        var changes: [Bool] = []
        lookup.onSlowChange = { changes.append($0) }

        lookup.start({ "profile" }, isStillWanted: { true }) { _ in }
        try await waitUntil { !lookup.isWaiting }

        #expect(changes.isEmpty)
        // 遅いと知らせるための待ちも残さない。
        #expect(clock.sleeperCount == 0)
    }

    /// 選び直しても待っていることに変わりはないので、出ているチップを引っ込めず、出すまでの時間も数え直さない。
    @Test func supersedingKeepsSlowState() async throws {
        let clock = TestClock()
        let lookup = LatestLookup(clock: clock, slowAfter: { .seconds(1) })
        var changes: [Bool] = []
        lookup.onSlowChange = { changes.append($0) }
        let first = Gate()
        let second = Gate()

        lookup.start(Self.work("first", after: first), isStillWanted: { true }) { _ in }
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        try await waitUntil { lookup.isSlow }
        lookup.start(Self.work("second", after: second), isStillWanted: { true }) { _ in }
        try await waitUntil { first.waiterCount == 0 && second.waiterCount == 1 }
        #expect(lookup.isSlow)
        #expect(clock.sleeperCount == 0)
        second.open()
        try await waitUntil { !lookup.isWaiting }

        #expect(changes == [true, false])
    }

    /// 「操作の状況」から止めたときなど。結果を渡さず、遅いという知らせも引っ込める。
    @Test func cancelDropsResultAndEndsSlow() async throws {
        let clock = TestClock()
        let lookup = LatestLookup(clock: clock, slowAfter: { .seconds(1) })
        let recorder = Recorder()
        var changes: [Bool] = []
        lookup.onSlowChange = { changes.append($0) }
        let gate = Gate()

        lookup.start(Self.work("profile", after: gate), isStillWanted: { true }) { recorder.results.append($0) }
        try await waitUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(1))
        try await waitUntil { lookup.isSlow }
        lookup.cancel()

        #expect(!lookup.isWaiting)
        #expect(!lookup.isSlow)
        try await waitUntil { gate.waiterCount == 0 }
        gate.open()
        #expect(recorder.results.isEmpty)
        #expect(changes == [true, false])
    }

    /// 遅いと知らせない入口は、時計を使わない。
    @Test func withoutSlowDelayNeverSleeps() async throws {
        let clock = TestClock()
        let lookup = LatestLookup(clock: clock, slowAfter: { nil })
        let gate = Gate()

        lookup.start(Self.work("profile", after: gate), isStillWanted: { true }) { _ in }
        try await waitUntil { gate.waiterCount == 1 }
        #expect(clock.sleeperCount == 0)
        gate.open()
        try await waitUntil { !lookup.isWaiting }
        #expect(!lookup.isSlow)
    }
}
