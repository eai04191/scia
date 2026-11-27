import Foundation
import Testing
import SciaTesting
@testable import SciaCore

/// プリセットより前の版の設定を、プリセットに移す（docs/preset.mdの「前の版からの移行」）。
@Suite(.scratch)
@MainActor
struct LegacySettingsMigrationTests {
    private func makeDefaults() -> UserDefaults {
        TestScratch.defaults("LegacySettingsMigrationTests")
    }

    /// 前の版の値を、前の版と同じ保存の形で書く。どれも標準と違う値。
    private func writeLegacyValues(to defaults: UserDefaults) {
        defaults.set(false, forKey: "settings.usesOriginalThumbnailsOnExpensiveNetwork")
        defaults.set(false, forKey: "settings.ignoresUselessAltText")
        defaults.set(false, forKey: "settings.showsStatusBarTicker")
        defaults.set(true, forKey: "settings.expandsXPosts")
        defaults.set(false, forKey: "settings.usesDynamicProfileAccent")
        defaults.set(false, forKey: "settings.separatesProfilePinned")
        defaults.set(false, forKey: "settings.showsProfileFeaturedTags")
        defaults.set(false, forKey: "settings.showsProfileEndorsements")
        defaults.set(ProfileNoteLength.allCases.first { $0 != .collapsed }?.rawValue, forKey: "settings.profileNoteLength")
        defaults.set(true, forKey: "settings.isAutoTranslationEnabled")
        defaults.set("fr", forKey: "settings.autoTranslationTarget")
        var appearance = AppearanceChoices()
        appearance.showsMedia = false
        defaults.set(appearance.storedData, forKey: "settings.appearanceChoices")
        defaults.set(InsertionMotion.allCases.first { $0 != .followsSystem }?.rawValue, forKey: "settings.insertionMotion")
        defaults.set(AccentColorChoice.orange.rawValue, forKey: "settings.accentColor")
        defaults.set(LinkBrowser.external.rawValue, forKey: "settings.linkBrowser")
        defaults.set(240.0, forKey: "settings.inAppBrowserSpaceAbove")
        defaults.set(true, forKey: "settings.opensInAppBrowserFullScreen")
        defaults.set(ReblogVisibility.allCases.first { $0 != .accountDefault }?.rawValue, forKey: "settings.reblogVisibility")
        defaults.set(Array(StatusMenuItem.defaultLayout.tokens.dropFirst()), forKey: "settings.statusMenuLayout")
        defaults.set(Array(PostActionBarItem.defaultLayout.tokens.dropFirst()), forKey: "settings.postActionBarLayout")
        defaults.set(true, forKey: "settings.showsActionBarItemsInMenu")
        defaults.set(ObjectActions<StatusMenuItem>(tap: .actionBar, longPress: .item(.favourite)).tokens, forKey: "settings.objectActions.status")
        defaults.set(true, forKey: "settings.hidesEmptyComposeBar")
        defaults.set(true, forKey: "settings.keepsComposeBarOpen")
        defaults.set(ImageUploadSize.original.rawValue, forKey: "settings.imageUploadSize")
        defaults.set(MediaDynamicRange.high.rawValue, forKey: "settings.mediaDynamicRange")
        defaults.set(3.0, forKey: "settings.appearance.\(AppearanceCatalog.bodyText.id)")
    }

    /// 前の版の値を「移行した設定」に移し、アプリのプリセットにする。移したキーは消す。
    @Test func movesLegacyValuesIntoPreset() throws {
        let defaults = makeDefaults()
        writeLegacyValues(to: defaults)

        let app = AppSettings(defaults: defaults)

        let library = app.store.library
        let migrated = try #require(library.userPresets.first)
        #expect(library.userPresets.count == 1)
        #expect(migrated.name == "移行した設定")
        #expect(migrated.parent == .builtIn(.standard))
        #expect(library.appPreset == .user(migrated.id))
        #expect(!app.usesOriginalThumbnailsOnExpensiveNetwork)
        #expect(!app.ignoresUselessAltText)
        #expect(!app.showsStatusBarTicker)
        #expect(app.expandsXPosts)
        #expect(!app.usesDynamicProfileAccent)
        #expect(!app.separatesProfilePinned)
        #expect(!app.showsProfileFeaturedTags)
        #expect(!app.showsProfileEndorsements)
        #expect(app.profileNoteLength != .collapsed)
        #expect(app.isAutoTranslationEnabled)
        #expect(app.autoTranslationTarget == "fr")
        #expect(!app.appearance.showsMedia)
        #expect(app.insertionMotion != .followsSystem)
        #expect(app.accentColor == .orange)
        #expect(app.linkBrowser == .external)
        #expect(app.inAppBrowserHeight == InAppBrowserHeight(spaceAbove: 240))
        #expect(app.opensInAppBrowserFullScreen)
        #expect(app.reblogVisibility != .accountDefault)
        #expect(app.statusMenuLayout == MenuLayout(tokens: Array(StatusMenuItem.defaultLayout.tokens.dropFirst())))
        #expect(app.postActionBarLayout == MenuLayout(tokens: Array(PostActionBarItem.defaultLayout.tokens.dropFirst())))
        #expect(app.showsActionBarItemsInMenu)
        #expect(app.statusActions == ObjectActions(tap: .actionBar, longPress: .item(.favourite)))
        #expect(app.hidesEmptyComposeBar)
        #expect(app.keepsComposeBarOpen)
        #expect(app.imageUploadSize == .original)
        #expect(app.mediaDynamicRange == .high)
        #expect(app.value(of: AppearanceCatalog.bodyText) == 3)
        #expect(defaults.object(forKey: "settings.accentColor") == nil)
        #expect(defaults.object(forKey: "settings.appearance.\(AppearanceCatalog.bodyText.id)") == nil)
    }

    /// プリセットは、移す値を揃えてから1回で保存する。途中で保存すると、そこでアプリが終わったとき、次の起動ではプリセットがあって移行を飛ばし、残りの値が移らないため。
    @Test func savesPresetsOnceWithAllValues() throws {
        let defaults = try #require(PresetsSaveRecorder(suiteName: TestScratch.suiteName("LegacySettingsMigrationTests")))
        writeLegacyValues(to: defaults)

        _ = AppSettings(defaults: defaults)

        #expect(defaults.saves.count == 1)
        let first = try #require(defaults.saves.first)
        let restarted = AppSettings(defaults: TestScratch.defaults("LegacySettingsMigrationTests.restarted"))
        restarted.store.updateLibrary { $0 = PresetLibrary(stored: first) }
        #expect(restarted.accentColor == .orange)
        #expect(restarted.expandsXPosts)
    }

    /// 端末で決まる既定値（Macでは投稿欄を開いたままにする）と違う前の値も移す。
    @Test func movesValueDifferentFromDeviceDefault() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "settings.keepsComposeBarOpen")

        let app = AppSettings(defaults: defaults, keepsComposeBarOpenByDefault: true)

        #expect(!app.keepsComposeBarOpen)
    }

    /// 標準と同じ値は書かない。変えていない項目まで、移したプリセットが変えた項目にしないため。
    @Test func skipsValuesSameAsStandard() throws {
        let defaults = makeDefaults()
        defaults.set(AccentColorChoice.blue.rawValue, forKey: "settings.accentColor")
        defaults.set(true, forKey: "settings.ignoresUselessAltText")
        defaults.set(LinkBrowser.external.rawValue, forKey: "settings.linkBrowser")

        let app = AppSettings(defaults: defaults)

        let migrated = try #require(app.store.library.userPresets.first)
        #expect(migrated.values.count == 1)
        #expect(app.linkBrowser == .external)
        #expect(app.accentColor == .blue)
    }

    /// 前の版の値がなければ、プリセットを作らない。
    @Test func doesNothingWithoutLegacyValues() {
        let app = AppSettings(defaults: makeDefaults())

        #expect(app.store.library.userPresets.isEmpty)
        #expect(app.store.library.appPreset == .builtIn(.standard))
    }

    /// プリセットをすでに持っていれば、前の版のキーが残っていても移さない。
    @Test func doesNothingWhenPresetsExist() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).store.updateLibrary { library throws(PresetError) in
            _ = try library.create(parent: .builtIn(.standard), name: "家")
        }
        defaults.set(AccentColorChoice.orange.rawValue, forKey: "settings.accentColor")

        let app = AppSettings(defaults: defaults)

        #expect(app.store.library.userPresets.map(\.name) == ["家"])
        #expect(app.accentColor == .blue)
    }

    /// 今の版も同じキーで端末に持つ値は、消さずに残す。
    @Test func keepsDeviceValues() {
        let defaults = makeDefaults()
        defaults.set(AccentColorChoice.orange.rawValue, forKey: "settings.accentColor")
        defaults.set(["en"], forKey: "settings.autoTranslationLanguages")
        defaults.set(["someone@example.social"], forKey: "settings.autoTranslationExcludedHandles")

        let app = AppSettings(defaults: defaults)

        #expect(app.autoTranslationLanguages == ["en"])
        #expect(app.autoTranslationExcludedHandles == ["someone@example.social"])
        #expect(defaults.stringArray(forKey: "settings.autoTranslationLanguages") == ["en"])
    }
}

/// 保存先の`settings.presets`に書かれた値を、書かれた順に記録する保存先。
private final class PresetsSaveRecorder: UserDefaults {
    private(set) var saves: [Data] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "settings.presets", let data = value as? Data {
            saves.append(data)
        }
        super.set(value, forKey: defaultName)
    }
}
