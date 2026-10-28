import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// 落ちたフレームに使った処理だけを、名前ごとに足し上げる。
@Suite(.scratch)
struct FrameWorkTests {
    private let frame = 1.0 / 60

    /// 間に合ったフレームの処理は数えず、落ちたフレームの処理を、そのフレームに割り当てて数える。
    @Test func countsOnlyWorkBeforeDroppedFrames() {
        var ledger = FrameWorkLedger()
        ledger.frame(timestamp: 0, targetTimestamp: frame)
        ledger.add("cell", seconds: 0.002)
        ledger.frame(timestamp: frame, targetTimestamp: frame * 2)
        ledger.add("header", seconds: 0.030)
        ledger.add("header", seconds: 0.010)
        ledger.add("cell", seconds: 0.004)
        // 2フレーム分遅れて届いた。
        ledger.frame(timestamp: frame * 4, targetTimestamp: frame * 5)
        ledger.add("cell", seconds: 0.001)
        ledger.frame(timestamp: frame * 5, targetTimestamp: frame * 6)

        let tally = ledger.finish()
        #expect(tally.droppedFrames == 2)
        #expect(tally.scrolls == 1)
        #expect(tally.entries == [
            "header": .init(total: 0.040, count: 2, longest: 0.030, frames: 1),
            "cell": .init(total: 0.004, count: 1, longest: 0.004, frames: 1),
        ])
        #expect(tally.top(1).map(\.name) == ["header"])
        #expect(abs(tally.measured - 0.044) < 1e-9)
    }

    /// フレームが落ちなかったスクロールは、回数にも数えない。
    @Test func smoothScrollLeavesEmptyTally() {
        var ledger = FrameWorkLedger()
        for index in 0..<10 {
            ledger.add("cell", seconds: 0.001)
            ledger.frame(timestamp: frame * Double(index), targetTimestamp: frame * Double(index + 1))
        }
        let tally = ledger.finish()
        #expect(tally.isEmpty)
        #expect(tally.scrolls == 0)
        #expect(tally.entries.isEmpty)
    }

    /// 保存した集計に足し上げ、起動し直しても読める。
    @Test func storeAccumulatesAcrossSaves() throws {
        let store = FrameWorkStore(file: TestScratch.url("FrameWorkTests", pathExtension: "json"))
        #expect(try store.load() == FrameWorkTally())
        let first = FrameWorkTally(entries: ["cell": .init(total: 0.01, count: 2, longest: 0.008, frames: 1)], droppedFrames: 1, hitchTime: 0.02, scrolls: 1)
        let second = FrameWorkTally(entries: ["cell": .init(total: 0.03, count: 1, longest: 0.03, frames: 1)], droppedFrames: 2, hitchTime: 0.04, scrolls: 1)
        try store.add(first)
        try store.add(second)

        let loaded = try store.load()
        #expect(loaded.droppedFrames == 3)
        #expect(loaded.scrolls == 2)
        #expect(loaded.entries["cell"] == .init(total: 0.04, count: 3, longest: 0.03, frames: 2))
    }
}
