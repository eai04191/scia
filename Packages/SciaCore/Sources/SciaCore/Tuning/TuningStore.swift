public import Foundation
public import Observation

/// チューニング項目の現在値を持つ。値の変更はObservationで購読できる。
@MainActor
@Observable
public final class TuningStore {
    public let items: [TuningItem]
    private var numbers: [String: Double] = [:]
    private var toggles: [String: Bool] = [:]
    @ObservationIgnored private let defaults: UserDefaults?

    /// - Parameter defaults: 変更した値の保存先。nilなら保存せず、起動のたびに既定値へ戻る。
    public init(items: [TuningItem] = TuningCatalog.items, defaults: UserDefaults?) {
        precondition(Set(items.map(\.id)).count == items.count, "チューニング項目のidが重複しています")
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

    /// すべての項目を既定値へ戻す。
    public func resetAll() {
        for item in items {
            defaults?.removeObject(forKey: Self.key(item.id))
        }
        numbers.removeAll()
        toggles.removeAll()
    }

    private static func key(_ id: String) -> String {
        "tuning.\(id)"
    }
}
