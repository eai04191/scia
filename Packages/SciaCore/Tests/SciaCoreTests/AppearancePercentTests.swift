import Testing
@testable import SciaCore

/// %で表示する見た目の項目は、範囲の上限を100%として出し、打った数を割合に戻す。保存する値は割合のまま。
struct AppearancePercentTests {
    @Test("角の丸さは、割合の上限0.5を100%として出す")
    func cornerRatioShowsHalfAsFull() {
        let item = AppearanceCatalog.avatarCornerRatio
        #expect(item.displayNumber(for: 0.5) == 100)
        #expect(item.displayNumber(for: 0.2) == 40)
        #expect(item.storedValue(fromDisplayNumber: 100) == 0.5)
        #expect(item.storedValue(fromDisplayNumber: 40) == 0.2)
    }

    @Test("不透明度は、割合の上限1を100%として出す")
    func opacityShowsOneAsFull() {
        let item = AppearanceCatalog.reactionGlowIconOpacity
        #expect(item.displayNumber(for: 0.6) == 60)
        #expect(item.storedValue(fromDisplayNumber: 60) == 0.6)
    }

    @Test("プリセットの比較でも、%の項目は%を添えて出す")
    @MainActor
    func comparisonShowsPercent() {
        #expect(PresetComparison.valueText(0.2, AppearanceCatalog.avatarCornerRatio) == "40%")
    }
}
