import CoreGraphics
import Testing
@testable import SciaCore

@MainActor
struct TimelineLoadTriggerTests {
    /// ナビゲーションバーの下から始まる、高さ600の表示領域。
    private let visibleRect = CGRect(x: 0, y: 100, width: 390, height: 600)

    private func row(y: CGFloat, height: CGFloat = 50) -> CGRect {
        CGRect(x: 0, y: y, width: 390, height: height)
    }

    /// 末尾の10行手前から読み始め、それより前では読まない。
    @Test func endStartsTenRowsBeforeLast() {
        #expect(!TimelineLoadTrigger.isApproachingEnd(displaying: 89, count: 100))
        #expect(TimelineLoadTrigger.isApproachingEnd(displaying: 90, count: 100))
        #expect(TimelineLoadTrigger.isApproachingEnd(displaying: 99, count: 100))
        // 10行に満たない一覧では、どの行でも読む。
        #expect(TimelineLoadTrigger.isApproachingEnd(displaying: 0, count: 5))
    }

    /// 表示領域の高さに`gapAutoLoadDistance`を掛けた距離まで上下に広げた中のギャップだけを拾う。
    @Test func gapsWithinTunedDistanceAreReported() {
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(0.5, for: TuningCatalog.gapAutoLoadDistance)
        // 表示領域は100〜700で、上下に300ずつ広げると-200〜1000。
        let gaps = [
            (id: "far-above", frame: row(y: -260)),
            (id: "near-above", frame: row(y: -240)),
            (id: "shown", frame: row(y: 300)),
            (id: "near-below", frame: row(y: 990)),
            (id: "far-below", frame: row(y: 1_001)),
        ]
        let reported = TimelineLoadTrigger.approachingGaps(gaps, in: visibleRect, scrollDirection: nil, tuning: tuning).map(\.id)
        #expect(reported == ["near-above", "shown", "near-below"])
    }

    /// 止まっているときは、表示領域の中央より上のギャップを古い側から、下のギャップを新しい側から読む。
    @Test func restingDirectionFollowsPositionOnScreen() {
        let gaps = [(id: "upper", frame: row(y: 200)), (id: "lower", frame: row(y: 500))]
        let reported = TimelineLoadTrigger.approachingGaps(gaps, in: visibleRect, scrollDirection: nil, tuning: TuningStore(defaults: nil))
        #expect(reported.map(\.direction) == [.fromOlder, .fromNewer])
    }

    /// 動かしている間は、画面上の位置によらず向きで決める。上へ戻るなら古い側から、下へ読み進めるなら新しい側から。
    @Test func scrollingDirectionOverridesPosition() {
        let gaps = [(id: "upper", frame: row(y: 200)), (id: "lower", frame: row(y: 500))]
        let tuning = TuningStore(defaults: nil)
        let towardNewer = TimelineLoadTrigger.approachingGaps(gaps, in: visibleRect, scrollDirection: .towardNewer, tuning: tuning)
        #expect(towardNewer.map(\.direction) == [.fromOlder, .fromOlder])
        let towardOlder = TimelineLoadTrigger.approachingGaps(gaps, in: visibleRect, scrollDirection: .towardOlder, tuning: tuning)
        #expect(towardOlder.map(\.direction) == [.fromNewer, .fromNewer])
    }
}
