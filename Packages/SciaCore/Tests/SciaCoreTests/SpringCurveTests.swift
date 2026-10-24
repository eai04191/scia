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

    /// バウンスしないスプリングは行き過ぎず、進み具合が戻らない。
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

    /// スワイプして離したときの速さを引き継ぐと、動き始めからその速さで進み、同じ時間のうちに1に落ち着く。
    @Test(arguments: [0.0, 0.3])
    func initialVelocityStartsMovingAtThatSpeed(bounce: Double) {
        let still = SpringCurve(duration: 0.4, bounce: bounce)
        let thrown = SpringCurve(duration: 0.4, bounce: bounce, initialVelocity: 8)
        let time = 0.001

        #expect(abs(thrown.value(at: time) / time - 8) < 0.2, "動き始めの速さ: \(thrown.value(at: time) / time)")
        #expect(thrown.value(at: 0.05) > still.value(at: 0.05))
        #expect(thrown.isSettled(at: 0.4 * 4))
        #expect(abs(thrown.value(at: 0.4 * 4) - 1) < 0.001)
    }

    /// バウンスしないスプリングは、抑えた上限の速さで動き始めても行き先を越えない。
    @Test func initialVelocityAtLimitDoesNotOvershootWithoutBounce() {
        let limit = SpringCurve.initialVelocity(releaseVelocity: (0, 1_000_000), from: (0, 0), to: (0, 100), duration: 0.4)
        let spring = SpringCurve(duration: 0.4, bounce: 0, initialVelocity: limit)

        #expect(abs(limit - 2 * Double.pi / 0.4) < 0.000_1)
        #expect((1...200).allSatisfy { spring.value(at: Double($0) * 0.01) <= 1 + 0.000_001 })
    }

    /// 行き先へ向かう向きの成分だけを、距離あたりの速さに直す。離れる向きと、行き先と同じ場所からは引き継がない。
    @Test func initialVelocityUsesOnlyTheComponentTowardTarget() {
        let toward = SpringCurve.initialVelocity(releaseVelocity: (300, 400), from: (0, 0), to: (0, 500), duration: 0.4)
        let away = SpringCurve.initialVelocity(releaseVelocity: (0, -400), from: (0, 0), to: (0, 500), duration: 0.4)
        let sameSpot = SpringCurve.initialVelocity(releaseVelocity: (0, 400), from: (10, 10), to: (10, 10), duration: 0.4)

        #expect(abs(toward - 0.8) < 0.000_1)
        #expect(away == 0)
        #expect(sameSpot == 0)
    }
}
