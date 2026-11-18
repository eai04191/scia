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

    /// 組み込みのプリセットでは、すき間の項目はどれも段の単位から決まり、段の大小を保つ。個々の値を並べると落ちる。
    @Test(arguments: BuiltInPreset.allCases)
    func builtInPresetKeepsSpacingScale(preset: BuiltInPreset) {
        let unit = preset.spacingUnit ?? SpacingScale.unit
        for item in AppearanceCatalog.values + NotificationAppearanceCatalog.values {
            guard case .spacing(let level) = item.role else { continue }
            let value = if case .number(let number)? = preset.values["appearanceValue.\(item.id)"] { number } else { item.defaultValue }
            #expect(value == level.value(unit: unit), "\(preset.title)の\(item.id)が\(value)で、段の\(level.value(unit: unit))と違います")
        }
    }
}
