public import Foundation
public import Observation

/// チューニング項目の現在値を持つ。値の変更はObservationで購読できる。
@MainActor
@Observable
public final class TuningStore {
    public let sections: [TuningSection]
    public let items: [TuningItem]
    private var numbers: [String: Double] = [:]
    private var toggles: [String: Bool] = [:]
    @ObservationIgnored private let defaults: UserDefaults?

    /// - Parameter defaults: 変更した値の保存先。nilなら保存せず、起動のたびに既定値へ戻る。
    public init(sections: [TuningSection] = TuningCatalog.sections, defaults: UserDefaults?) {
        let items = sections.flatMap(\.items)
        precondition(Set(items.map(\.id)).count == items.count, "チューニング項目のidが重複しています")
        precondition(Set(sections.map(\.id)).count == sections.count, "チューニングのカテゴリのidが重複しています")
        self.sections = sections
        self.items = items
        self.defaults = defaults
        for item in items {
            switch item {
            case .number(let tuning):
                if let stored = defaults?.object(forKey: Self.key(tuning.id)) as? Double, tuning.range.contains(stored) {
                    numbers[tuning.id] = stored
                }
            case .toggle(let tuning):
                if let stored = defaults?.object(forKey: Self.key(tuning.id)) as? Bool {
                    toggles[tuning.id] = stored
                }
            }
        }
    }

    public func value(of tuning: NumberTuning) -> Double {
        numbers[tuning.id] ?? tuning.defaultValue
    }

    public func value(of tuning: ToggleTuning) -> Bool {
        toggles[tuning.id] ?? tuning.defaultValue
    }

    /// 範囲外の値は範囲内に丸めて保存する。
    public func setValue(_ value: Double, for tuning: NumberTuning) {
        let clamped = min(max(value, tuning.range.lowerBound), tuning.range.upperBound)
        numbers[tuning.id] = clamped
        defaults?.set(clamped, forKey: Self.key(tuning.id))
    }

    public func setValue(_ value: Bool, for tuning: ToggleTuning) {
        toggles[tuning.id] = value
        defaults?.set(value, forKey: Self.key(tuning.id))
    }

    /// 項目が既定値から変わっているか。
    public func isModified(_ item: TuningItem) -> Bool {
        switch item {
        case .number(let tuning): value(of: tuning) != tuning.defaultValue
        case .toggle(let tuning): value(of: tuning) != tuning.defaultValue
        }
    }

    /// いずれかの項目が既定値から変わっているか。
    public func isModified(_ section: TuningSection) -> Bool {
        section.items.contains(where: isModified)
    }

    /// 項目を既定値へ戻す。
    public func reset(_ item: TuningItem) {
        reset([item])
    }

    /// カテゴリの項目を既定値へ戻す。
    public func reset(_ section: TuningSection) {
        reset(section.items)
    }

    /// すべての項目を既定値へ戻す。
    public func resetAll() {
        reset(items)
    }

    private func reset(_ items: [TuningItem]) {
        for item in items {
            defaults?.removeObject(forKey: Self.key(item.id))
            numbers[item.id] = nil
            toggles[item.id] = nil
        }
    }

    private static func key(_ id: String) -> String {
        "tuning.\(id)"
    }
}
