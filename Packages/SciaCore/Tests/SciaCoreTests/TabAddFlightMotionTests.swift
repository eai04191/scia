import CoreGraphics
import Testing
@testable import SciaCore

/// 「タブに追加」で飛ばすアイコンの、飛ぶ間の位置と倍率。
/// 期待値は、値を決めたブラウザのエディタで同じ値を計算した結果。アプリの動きがエディタで見た動きとずれていないことを確かめる。
struct TabAddFlightMotionTests {
    private let start = CGPoint(x: 306, y: 84)
    private let end = CGPoint(x: 350, y: 822)

    @Test("エディタで計算した位置と倍率に一致する", arguments: [
        (0.1, 303.6353933477366, 84.67203427881722, 0.9906234960629922, 1.0),
        (0.5, 256.51089227096, 132.69402237092214, 0.9573530938023538, 1.0),
        (0.8, 251.92343427132369, 374.04304759038945, 0.94753439659594, 1.0),
        (0.95, 313.13909447427955, 677.1575297048993, 0.574959648471756, 0.5),
    ])
    func matchesEditor(progress: Double, x: Double, y: Double, scale: Double, opacity: Double) {
        let sample = TabAddFlightMotion.sample(at: progress, from: start, to: end)
        #expect(abs(sample.position.x - x) < 0.01)
        #expect(abs(sample.position.y - y) < 0.01)
        #expect(abs(sample.scale - scale) < 0.0001)
        #expect(abs(sample.opacity - opacity) < 0.0001)
    }

    @Test("飛び立つ点から倍率1で始まり、着く点で終わる")
    func startsAndEndsAtEndpoints() {
        let samples = TabAddFlightMotion.samples(count: 60, from: start, to: end)
        #expect(samples.count == 61)
        #expect(samples.first == .init(position: start, scale: 1, opacity: 1))
        #expect(samples.last?.position == end)
        #expect(samples.last?.opacity == 0)
    }

    @Test("cubic-bezierは両端で0と1になり、横の位置に対して進み具合を返す")
    func unitBezier() {
        let linear = UnitBezier(x1: 0, y1: 0, x2: 1, y2: 1)
        #expect(abs(linear.value(at: 0.3) - 0.3) < 1e-6)
        #expect(TabAddFlightMotion.positionTiming.value(at: 0) == 0)
        #expect(TabAddFlightMotion.positionTiming.value(at: 1) == 1)
    }

    @Test("キーフレームの曲線は、なめらかにつないでも点を通る")
    func keyframePassesThroughPoints() {
        for point in TabAddFlightMotion.scaleMultiplier.points {
            #expect(abs(TabAddFlightMotion.scaleMultiplier.value(at: point.time) - point.value) < 1e-9)
        }
        #expect(abs(TabAddFlightMotion.opacityMultiplier.value(at: 0.95) - 0.5) < 1e-9)
    }
}
