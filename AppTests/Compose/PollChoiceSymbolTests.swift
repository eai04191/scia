import SwiftUI
import Testing
@testable import Scia

/// 投票の選び方のボタンのアイコン。
@MainActor
@Suite(.failureState)
struct PollChoiceSymbolTests {
    private let rect = CGRect(x: 0, y: 0, width: 120, height: 100)
    /// 標準、「文字を太くする」、極太。
    private let weights: [CGFloat] = [0, PollChoiceSymbolMetrics.boldTextWeight, 1]

    private func path(_ part: PollChoiceSymbolShape.Part, progress: CGFloat, metrics: PollChoiceSymbolMetrics) -> Path {
        PollChoiceSymbolShape(progress: progress, part: part, metrics: metrics).path(in: rect)
    }

    /// 引き終えたチェックマークは、輪郭の全体が見える。なぞる線が輪郭より細かったり、ずれていたりすると、端が欠けたまま終わる。
    @Test func drawnCheckRevealsTheWholeOutline() {
        for weight in weights {
            let metrics = PollChoiceSymbolMetrics.interpolated(weight)
            for row in [metrics.topRowY, metrics.bottomRowY] {
                let outline = path(.check(row: row), progress: 1, metrics: metrics)
                let stroke = path(.checkStroke(row: row, drawn: 1), progress: 1, metrics: metrics)
                var uncovered: [CGPoint] = []
                outline.forEach { element in
                    switch element {
                    case let .move(to), let .line(to), let .curve(to, _, _), let .quadCurve(to, _):
                        if !stroke.contains(to) {
                            uncovered.append(to)
                        }
                    case .closeSubpath:
                        break
                    }
                }
                #expect(uncovered.isEmpty, "weight \(weight) row \(row): \(uncovered)")
            }
        }
    }

    /// 引く前は、チェックマークが見えない。
    @Test func undrawnCheckRevealsNothing() {
        let metrics = PollChoiceSymbolMetrics.interpolated(0)
        #expect(path(.checkStroke(row: metrics.bottomRowY, drawn: 0), progress: 0, metrics: metrics).isEmpty)
    }

    /// 横線は、切り替えの途中でも動かない。先頭の形だけが、丸から四角へ小さくなる。
    @Test func linesStayWhileMarkersShrink() {
        let metrics = PollChoiceSymbolMetrics.interpolated(0)
        let bounds = [0, 0.5, 1].map { path(.fill, progress: $0, metrics: metrics).boundingRect }
        // 右端は横線、左端は先頭の形。
        #expect(abs(bounds[0].maxX - bounds[1].maxX) < 0.001, "\(bounds[0].maxX) \(bounds[1].maxX)")
        #expect(abs(bounds[1].maxX - bounds[2].maxX) < 0.001, "\(bounds[1].maxX) \(bounds[2].maxX)")
        #expect(bounds[0].minX < bounds[1].minX)
        #expect(bounds[1].minX < bounds[2].minX)
    }
}
