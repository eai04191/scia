import Testing
@testable import SciaCore

struct SpringCurveTests {
    @Test func startsAtZeroAndSettlesAtOne() {
        let spring = SpringCurve(duration: 0.4, bounce: 0)

        #expect(spring.value(at: 0) == 0)
        #expect(abs(spring.value(at: 1.2) - 1) < 0.001)
        #expect(spring.isSettled(at: 1.2))
        #expect(!spring.isSettled(at: 0.2))
    }

    /// 弾まないばねは行き過ぎず、進み具合が戻らない。
    @Test func withoutBounceIncreasesMonotonicallyWithoutOvershoot() {
        let spring = SpringCurve(duration: 0.4, bounce: 0)
        var previous = 0.0
        for step in 1...100 {
            let value = spring.value(at: Double(step) * 0.01)
            #expect(value >= previous)
            #expect(value <= 1)
            previous = value
        }
    }

    @Test func bounceOvershootsOnce() {
        let spring = SpringCurve(duration: 0.4, bounce: 0.3)
        let peak = (1...100).map { spring.value(at: Double($0) * 0.01) }.max() ?? 0

        #expect(peak > 1)
        #expect(spring.isSettled(at: 1.6))
    }

    /// 落ち着かないまま長く続かないよう、時間の4倍で打ち切る。
    @Test func alwaysFinishesWithinFourTimesTheDuration() {
        #expect(SpringCurve(duration: 0.4, bounce: 0.9).isSettled(at: 1.6))
    }
}
