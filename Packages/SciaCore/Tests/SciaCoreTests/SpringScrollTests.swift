import Testing
@testable import SciaCore

struct SpringScrollTests {
    private let frame = 1.0 / 60

    /// 落ち着くまで1フレームずつ進め、置いた位置を並べる。`correction`で、各フレームの前に位置をずらせる。
    private func run(
        _ scroll: inout SpringScroll,
        from start: Double,
        target: (Int) -> Double = { _ in 0 },
        correction: (Int, Double) -> Double = { _, _ in 0 }
    ) -> [Double] {
        var positions: [Double] = []
        var position = start
        for index in 0..<600 {
            position += correction(index, position)
            position = scroll.step(from: position, toward: target(index), by: frame)
            positions.append(position)
            if scroll.isSettled(at: position, target: target(index)) { break }
        }
        return positions
    }

    private func largestStep(_ positions: [Double]) -> Double {
        zip(positions, positions.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    /// 止まった状態から動かすと、同じ時間と弾みの`SpringCurve`と同じ道筋をたどる。
    @Test(arguments: [0.0, 0.3])
    func matchesSpringCurveFromRest(bounce: Double) {
        let curve = SpringCurve(duration: 0.4, bounce: bounce)
        var scroll = SpringScroll(duration: 0.4, bounce: bounce)

        let positions = run(&scroll, from: 1_000)

        for (index, position) in positions.enumerated() {
            let expected = 1_000 * (1 - curve.value(at: Double(index + 1) * frame))
            #expect(abs(position - expected) < 0.01, "フレーム\(index)で\(position - expected)pt外れました")
        }
        #expect(abs(positions.last ?? .infinity) < 0.5)
        #expect(Double(positions.count) * frame < 0.4 * 4, "落ち着くまでに時間がかかりすぎます")
    }

    /// 動きの終わりぎわに新着を足して距離が伸びても、急に速くならず、止まってから動き直しもしない。
    /// 速さを持ち越すため、止まった状態から同じ距離を動かすときと同じくらいの速さで動く。
    @Test func lateInsertionDoesNotJumpOrStall() {
        var scroll = SpringScroll(duration: 0.4, bounce: 0)
        let insertionFrame = 25
        let positions = run(&scroll, from: 400, correction: { index, _ in index == insertionFrame ? 400 : 0 })

        var fresh = SpringScroll(duration: 0.4, bounce: 0)
        let freshLargest = largestStep(run(&fresh, from: 400))
        let afterInsertion = Array(positions[insertionFrame...])
        #expect(largestStep(afterInsertion) <= freshLargest * 1.1, "足した直後に1フレームで\(largestStep(afterInsertion))pt動きました")
        // 足した直後も、目標へ向かって動き続ける。
        let firstSteps = zip(afterInsertion, afterInsertion.dropFirst()).prefix(3).map { $0 - $1 }
        #expect(firstSteps.allSatisfy { $0 > 0.5 }, "足した直後に止まりました: \(firstSteps)")
        #expect(abs(positions.last ?? .infinity) < 0.5)
    }

    /// 途中で上のセルが実寸になり、位置が補正されても、補正した位置から続けて目標に行き着く。
    @Test(arguments: [0.0, 0.3])
    func reachesTargetDespiteCorrections(bounce: Double) {
        var scroll = SpringScroll(duration: 0.4, bounce: bounce)

        let positions = run(&scroll, from: 3_000, correction: { index, position in
            index % 7 == 3 && position > 200 ? 80 : 0
        })

        #expect(abs(positions.last ?? .infinity) < 0.5, "目標に行き着いていません: \(positions.last ?? .nan)")
    }

    /// 動いている途中に目標が変わっても、位置は飛ばず、新しい目標へ向かう。
    @Test func movingTargetDoesNotJump() {
        var scroll = SpringScroll(duration: 0.4, bounce: 0)

        let positions = run(&scroll, from: 500, target: { $0 < 10 ? 0 : -50 })

        #expect(largestStep(positions) < 60)
        #expect(abs((positions.last ?? .infinity) - -50) < 0.5)
    }

    /// 置いた位置が画素に丸められても、終わりぎわの小さな動きが打ち消されず、落ち着く。
    @Test(arguments: [0.0, 0.3])
    func settlesWhenPositionsAreRoundedToPixels(bounce: Double) {
        var scroll = SpringScroll(duration: 1.5, bounce: bounce)
        var position = 600.0
        var settled = false
        var frames = 0
        // 時間の4倍（60fpsで360フレーム）までに落ち着く。
        while !settled, frames < 360 {
            let next = scroll.step(from: position, toward: -116, by: frame)
            settled = scroll.isSettled(at: next, target: -116)
            position = (next * 3).rounded() / 3
            frames += 1
        }

        #expect(settled, "落ち着きませんでした: \(position)")
    }

    /// 弾むばねは目標を一度行き過ぎてから戻る。
    @Test func bounceOvershootsTarget() {
        var scroll = SpringScroll(duration: 0.4, bounce: 0.3)

        let positions = run(&scroll, from: 1_000)

        #expect((positions.min() ?? 0) < -1)
        #expect(abs(positions.last ?? .infinity) < 0.5)
    }
}
