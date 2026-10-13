import Foundation
import Testing
@testable import SciaCore

@MainActor
struct TuningStoreTests {
    private let interval = NumberTuning(id: "interval", title: "挿入間隔", range: 0...5, step: 0.1, defaultValue: 1)
    private let follow = ToggleTuning(id: "follow", title: "自動追従", defaultValue: true)
    private var items: [TuningItem] { [.number(interval), .toggle(follow)] }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "TuningStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func returnsDefaultValuesInitially() throws {
        let store = TuningStore(items: items, defaults: try makeDefaults())

        #expect(store.value(of: interval) == 1)
        #expect(store.value(of: follow) == true)
    }

    @Test func persistsChangedValuesAcrossInstances() throws {
        let defaults = try makeDefaults()
        let store = TuningStore(items: items, defaults: defaults)
        store.setValue(2.5, for: interval)
        store.setValue(false, for: follow)

        let reloaded = TuningStore(items: items, defaults: defaults)
        #expect(reloaded.value(of: interval) == 2.5)
        #expect(reloaded.value(of: follow) == false)
    }

    @Test func clampsOutOfRangeValues() throws {
        let store = TuningStore(items: items, defaults: try makeDefaults())
        store.setValue(10, for: interval)

        #expect(store.value(of: interval) == 5)
    }

    @Test func ignoresStoredValueOutsideCurrentRange() throws {
        let defaults = try makeDefaults()
        defaults.set(10.0, forKey: "tuning.interval")

        let store = TuningStore(items: items, defaults: defaults)
        #expect(store.value(of: interval) == 1)
    }

    @Test func resetAllRestoresDefaultsAndClearsStorage() throws {
        let defaults = try makeDefaults()
        let store = TuningStore(items: items, defaults: defaults)
        store.setValue(3, for: interval)
        store.setValue(false, for: follow)
        store.resetAll()

        #expect(store.value(of: interval) == 1)
        #expect(store.value(of: follow) == true)
        #expect(TuningStore(items: items, defaults: defaults).value(of: interval) == 1)
    }

    @Test func withoutDefaultsDoesNotPersist() {
        let store = TuningStore(items: items, defaults: nil)
        store.setValue(4, for: interval)

        #expect(store.value(of: interval) == 4)
        #expect(TuningStore(items: items, defaults: nil).value(of: interval) == 1)
    }

    @Test func notifiesObserversOnChange() throws {
        let store = TuningStore(items: items, defaults: try makeDefaults())
        let changed = Flag()
        withObservationTracking {
            _ = store.value(of: interval)
        } onChange: {
            // onChangeは値を変更したスレッドで同期的に呼ばれるため、ここではMainActor上にいる。
            MainActor.assumeIsolated { changed.isSet = true }
        }
        store.setValue(2, for: interval)

        #expect(changed.isSet)
    }
}

@MainActor
private final class Flag {
    var isSet = false
}
