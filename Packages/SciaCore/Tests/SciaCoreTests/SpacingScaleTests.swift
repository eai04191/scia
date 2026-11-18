import SciaCore
import Testing

/// すき間の段（`SpacingScale`）の決まりを、項目とプリセットが守る。
struct SpacingScaleTests {
    /// 長さの項目は、すき間の段か段によらない長さかを必ず宣言する。項目を足すときに段を決め忘れると落ちる。
    @Test(arguments: AppearanceCatalog.values + NotificationAppearanceCatalog.values)
    func lengthItemDeclaresRole(item: AppearanceValue) {
        guard item.unit == .point else { return }
        #expect(item.role != nil, "\(item.id)は長さの項目なのに、役割を宣言していません")
    }

    /// 組み込みのプリセットでは、すき間の項目はどれも段の長さから決まる。個々の値を並べると落ちる。
    @Test(arguments: BuiltInPreset.allCases)
    func builtInPresetKeepsSpacingScale(preset: BuiltInPreset) {
        for item in AppearanceCatalog.values + NotificationAppearanceCatalog.values {
            guard case .spacing(let level) = item.role else { continue }
            let expected = preset.spacing?[level] ?? level.value()
            let value = if case .number(let number)? = preset.values["appearanceValue.\(item.id)"] { number } else { item.defaultValue }
            #expect(value == expected, "\(preset.title)の\(item.id)が\(value)で、段の\(expected)と違います")
        }
    }

    /// どのプリセットでも、近いものほど狭い（S1 < S2 < S3 < S4）。
    @Test(arguments: BuiltInPreset.allCases)
    func builtInPresetKeepsSpacingOrder(preset: BuiltInPreset) {
        let values = SpacingScale.Level.allCases.map { preset.spacing?[$0] ?? $0.value() }
        #expect(values == values.sorted() && Set(values).count == values.count, "\(preset.title)の段\(values)が、近いものほど狭くなっていません")
    }
}
