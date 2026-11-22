import SciaCore
import Testing

/// 120Hzで刻む時計で読んだ値が2刻みごとにしか変わらないとき、60Hzで動いていると読めるように数えるか確かめる。
struct FrameChangeSummaryTests {
    private func samples(_ values: [Double], interval: Double = 1.0 / 120) -> [FrameChangeSummary.Sample] {
        values.enumerated().map { FrameChangeSummary.Sample(time: Double($0.offset) * interval, value: $0.element) }
    }

    @Test func countsEveryOtherTickAsTwoTickGaps() throws {
        let summary = try #require(FrameChangeSummary(samples: samples([0, 0, 1, 1, 2, 2, 3, 3, 3])))
        #expect(summary.changes == 3)
        #expect(summary.ticks == 5)
        #expect(summary.changeGaps == [2: 2])
        #expect(abs(summary.medianTickInterval - 1.0 / 120) < 1e-9)
    }

    @Test func countsEveryTickAsOneTickGaps() throws {
        let summary = try #require(FrameChangeSummary(samples: samples([0, 1, 2, 3, 3])))
        #expect(summary.changeGaps == [1: 2])
        #expect(summary.text == "刻み=3 変化=3 刻みの間隔=8.3ms 変化の間隔: 1刻み×2")
    }

    /// 1回しか変わらないと範囲を決められない。決めようとして範囲が逆転すると落ちる。
    @Test func returnsNilWhenValueChangesOnce() {
        #expect(FrameChangeSummary(samples: samples([0, 0, 1, 1])) == nil)
        #expect(FrameChangeSummary(samples: samples([0, 0])) == nil)
        #expect(FrameChangeSummary(samples: []) == nil)
    }
}
