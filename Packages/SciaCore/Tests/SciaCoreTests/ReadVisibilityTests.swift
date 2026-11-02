import CoreGraphics
import Testing
@testable import SciaCore

struct ReadVisibilityTests {
    /// ナビゲーションバーの下から始まる、高さ600の表示領域。
    private let visibleRect = CGRect(x: 0, y: 100, width: 390, height: 600)

    private func row(y: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: 0, y: y, width: 390, height: height)
    }

    /// 行の高さの半分以上が入っていれば既読にし、半分に届かなければしない。
    @Test func rowCountsWhenHalfIsVisible() {
        // 上端から半分だけ隠れている。
        #expect(ReadVisibility.isVisible(row(y: 50, height: 100), in: visibleRect))
        // 半分より多く隠れている。
        #expect(!ReadVisibility.isVisible(row(y: 49, height: 100), in: visibleRect))
        // 下端から半分だけ出ている。
        #expect(ReadVisibility.isVisible(row(y: 650, height: 100), in: visibleRect))
        #expect(!ReadVisibility.isVisible(row(y: 651, height: 100), in: visibleRect))
        // 少しもかかっていない。
        #expect(!ReadVisibility.isVisible(row(y: 800, height: 100), in: visibleRect))
    }

    /// 表示領域より高い行は、表示領域の半分以上を占めていれば既読にする。行の半分は一度に見えないため。
    @Test func tallRowCountsWhenItFillsHalfOfVisibleArea() {
        #expect(ReadVisibility.isVisible(row(y: 400, height: 2_000), in: visibleRect))
        #expect(!ReadVisibility.isVisible(row(y: 401, height: 2_000), in: visibleRect))
    }

    @Test func visibleIDsKeepOrder() {
        let rows = [
            (id: "hidden-above", frame: row(y: 0, height: 100)),
            (id: "a", frame: row(y: 100, height: 300)),
            (id: "b", frame: row(y: 400, height: 300)),
            (id: "peeking-below", frame: row(y: 690, height: 100)),
        ]
        #expect(ReadVisibility.visibleIDs(of: rows, in: visibleRect) == ["a", "b"])
    }

    /// 見ていない間は報告しない。窓が前面にない間は、使う人がスクロールしたときだけ報告する。
    @Test func reportsOnlyWhileShown() {
        #expect(ReadVisibility.shouldReport(isShown: true, isWindowActive: true, byUser: false))
        #expect(!ReadVisibility.shouldReport(isShown: false, isWindowActive: true, byUser: true))
        #expect(!ReadVisibility.shouldReport(isShown: true, isWindowActive: false, byUser: false))
        #expect(ReadVisibility.shouldReport(isShown: true, isWindowActive: false, byUser: true))
    }
}
