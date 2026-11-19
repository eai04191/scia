import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

@Suite(.scratch, .failureState)
@MainActor
struct PostRenderSettingsTests {
    @Test func reusesValuesUntilSettingsChange() {
        let settings = AppSettings.isolated()
        let cache = PostRenderSettings(settings: settings)
        let first = cache.read()
        #expect(first === cache.read())

        settings.setValue(3, for: AppearanceCatalog.bodyText)
        settings.setValue(5, for: AppearanceCatalog.bodyText)
        let changed = cache.read()
        #expect(changed !== first)
        #expect(changed.value(of: AppearanceCatalog.bodyText) == 5)
        #expect(changed.typography == PostTypography(settings: settings))
        #expect(changed === cache.read())

        settings.appearance.showsAvatar.toggle()
        #expect(cache.read().appearance == settings.appearance)
        #expect(cache.read() !== changed)
        settings.setValue(8, for: AppearanceCatalog.rowPaddingTop)
        #expect(cache.read().rowMargins == settings.rowMargins)
        settings.reset([AppearanceCatalog.bodyText, AppearanceCatalog.rowPaddingTop])
        #expect(cache.read().typography == PostTypography(settings: settings))
        #expect(cache.read().rowMargins == settings.rowMargins)
    }

    @Test func followsParentEditsDeletionAndShortcutSelection() throws {
        let app = AppSettings.isolated()
        var parent = PresetID.builtIn(.standard)
        var child = parent
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            parent = try library.create(parent: .builtIn(.standard), name: "親")
            child = try library.create(parent: parent, name: "子")
            try library.select(child, for: .account("one@example.com"))
        }
        let settings = app.forAccount("one@example.com")
        let cache = PostRenderSettings(settings: settings)
        let preview = PostRenderSettings(settings: settings.editing(child))
        let other = PostRenderSettings(settings: app.forAccount("two@example.com"))
        let otherTypography = other.read().typography
        _ = cache.read()
        _ = preview.read()
        app.editing(parent).setValue(6, for: AppearanceCatalog.bodyText)
        #expect(cache.read().value(of: AppearanceCatalog.bodyText) == 6)
        #expect(preview.read().typography == cache.read().typography)
        #expect(other.read().typography == otherTypography)

        try app.store.tryUpdateLibrary { library throws(PresetError) in try library.delete(parent) }
        #expect(cache.read().typography == PostTypography(settings: settings))
        settings.reset([AppearanceCatalog.bodyText])
        #expect(cache.read().typography == PostTypography(settings: settings))
        #expect(preview.read().typography == cache.read().typography)

        try app.store.applyShortcut(selecting: .builtIn(.compact), for: .account("one@example.com"), signedInAccounts: ["one@example.com", "two@example.com"])
        #expect(cache.read().appearance == settings.appearance)
        #expect(cache.read().typography == PostTypography(settings: settings))
        #expect(preview.read().typography == PostTypography(settings: settings.editing(child)))
        #expect(other.read().typography == otherTypography)
    }

    @Test func retainedBuilderReadsCurrentValuesAndHonorsAppearanceOverride() throws {
        let settings = AppSettings.isolated()
        let cache = PostRenderSettings(settings: settings)
        var builder = PostContentBuilder(tuning: TuningStore(defaults: nil), renderSettings: cache, emojiImages: .offline, mediaImages: .offline, avatarImages: .offline)
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let before = builder.configuration(for: status, base: .cell())
        settings.setValue(6, for: AppearanceCatalog.bodyText)
        let after = builder.configuration(for: status, base: .cell())
        #expect(!before.body.isEqual(to: after.body))
        #expect(after.metrics.nameFont == PostTypography(settings: settings).font(.namePrimary))

        var override = settings.appearance
        override.showsAvatar = false
        builder.appearanceOverride = override
        let hidden = builder.configuration(for: status, base: .cell())
        #expect(hidden.metrics.avatarSize == 0)
        #expect(hidden.metrics.avatarSpacing == 0)
        #expect(hidden.avatar == nil)
    }

    @Test func cachedTypographyStillScalesWithDynamicType() {
        let cache = PostRenderSettings(settings: .isolated())
        let values = cache.read()
        let standard = values.typography.font(.body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let larger = values.typography.font(.body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge))
        #expect(larger.pointSize > standard.pointSize)
        #expect(values === cache.read())
    }
}
