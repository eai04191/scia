import Foundation
import Testing
@testable import SciaCore

@MainActor
struct TuningStoreTests {
    private let interval = NumberTuning(id: "interval", title: "挿入間隔", range: 0...5, step: 0.1, defaultValue: 1)
    private let follow = ToggleTuning(id: "follow", title: "自動追従", defaultValue: true)
    private let spacing = NumberTuning(id: "spacing", title: "段落間隔", range: 0...24, step: 1, defaultValue: 6)
    private var streaming: TuningSection {
        TuningSection(id: "streaming", title: "新着", items: [.number(interval), .toggle(follow)])
    }
    private var appearance: TuningSection {
        TuningSection(id: "appearance", title: "見た目", items: [.number(spacing)])
    }
    private var items: [TuningSection] { [streaming, appearance] }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "TuningStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func returnsDefaultValuesInitially() throws {
        let store = TuningStore(sections: items, defaults: try makeDefaults())

        #expect(store.value(of: interval) == 1)
        #expect(store.value(of: follow) == true)
    }

    @Test func persistsChangedValuesAcrossInstances() throws {
        let defaults = try makeDefaults()
        let store = TuningStore(sections: items, defaults: defaults)
        store.setValue(2.5, for: interval)
        store.setValue(false, for: follow)

        let reloaded = TuningStore(sections: items, defaults: defaults)
        #expect(reloaded.value(of: interval) == 2.5)
        #expect(reloaded.value(of: follow) == false)
    }

    @Test func clampsOutOfRangeValues() throws {
        let store = TuningStore(sections: items, defaults: try makeDefaults())
        store.setValue(10, for: interval)

        #expect(store.value(of: interval) == 5)
    }

    @Test func ignoresStoredValueOutsideCurrentRange() throws {
        let defaults = try makeDefaults()
        defaults.set(10.0, forKey: "tuning.interval")

        let store = TuningStore(sections: items, defaults: defaults)
        #expect(store.value(of: interval) == 1)
    }

    @Test func resetAllRestoresDefaultsAndClearsStorage() throws {
        let defaults = try makeDefaults()
        let store = TuningStore(sections: items, defaults: defaults)
        store.setValue(3, for: interval)
        store.setValue(false, for: follow)
        store.resetAll()

        #expect(store.value(of: interval) == 1)
        #expect(store.value(of: follow) == true)
        #expect(TuningStore(sections: items, defaults: defaults).value(of: interval) == 1)
    }

    @Test func resetSectionRestoresOnlyItsItems() throws {
        let defaults = try makeDefaults()
        let store = TuningStore(sections: items, defaults: defaults)
        store.setValue(3, for: interval)
        store.setValue(false, for: follow)
        store.setValue(12, for: spacing)
        store.reset(streaming)

        #expect(store.value(of: interval) == 1)
        #expect(store.value(of: follow) == true)
        #expect(store.value(of: spacing) == 12)
        let reloaded = TuningStore(sections: items, defaults: defaults)
        #expect(reloaded.value(of: interval) == 1)
        #expect(reloaded.value(of: spacing) == 12)
    }

    @Test func isModifiedComparesWithDefaultValues() throws {
        let store = TuningStore(sections: items, defaults: try makeDefaults())
        #expect(!store.isModified(streaming))

        store.setValue(false, for: follow)
        #expect(store.isModified(streaming))
        #expect(!store.isModified(appearance))

        // 既定値と同じ値に戻したら、変更していない扱いにする。
        store.setValue(true, for: follow)
        #expect(!store.isModified(streaming))
    }

    @Test func resetItemRestoresOnlyThatItem() throws {
        let defaults = try makeDefaults()
        let store = TuningStore(sections: items, defaults: defaults)
        store.setValue(3, for: interval)
        store.setValue(false, for: follow)
        store.reset(.number(interval))

        #expect(store.value(of: interval) == 1)
        #expect(store.value(of: follow) == false)
        let reloaded = TuningStore(sections: items, defaults: defaults)
        #expect(reloaded.value(of: interval) == 1)
        #expect(reloaded.value(of: follow) == false)
    }

    @Test func isModifiedItemComparesWithDefaultValue() throws {
        let store = TuningStore(sections: items, defaults: try makeDefaults())
        #expect(!store.isModified(.number(interval)))

        store.setValue(3, for: interval)
        #expect(store.isModified(.number(interval)))
        #expect(!store.isModified(.toggle(follow)))

        // 既定値と同じ値に戻したら、変更していない扱いにする。
        store.setValue(1, for: interval)
        #expect(!store.isModified(.number(interval)))
    }

    @Test func withoutDefaultsDoesNotPersist() {
        let store = TuningStore(sections: items, defaults: nil)
        store.setValue(4, for: interval)

        #expect(store.value(of: interval) == 4)
        #expect(TuningStore(sections: items, defaults: nil).value(of: interval) == 1)
    }

    @Test func notifiesObserversOnChange() throws {
        let store = TuningStore(sections: items, defaults: try makeDefaults())
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
