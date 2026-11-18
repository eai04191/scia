import Foundation
import Testing
import SciaTesting
@testable import SciaCore

/// 設定の値を、画面をたどらずにキーで読み書きする（`scia-debug://settings`）。
@Suite(.scratch)
@MainActor
struct SettingsDirectAccessTests {
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: TestScratch.defaults("SettingsDirectAccessTests")).forAccount("me@example.com")
    }

    /// 書いた値は、画面で変えたときと同じ設定の値として読める。
    @Test func writesThroughThePreset() throws {
        let settings = makeSettings()
        try settings.setDirectly(PresetValue(json: "false"), forKey: AppSettings.Keys.usesOriginalThumbnailsOnExpensiveNetwork, account: "me@example.com")
        #expect(!settings.usesOriginalThumbnailsOnExpensiveNetwork)

        try settings.setDirectly(PresetValue(json: "\"circle\""), forKey: AppearanceStorage.key(AppearanceChoice.avatarShape.field), account: "me@example.com")
        #expect(settings.appearance.avatarShape == .circle)

        try settings.setDirectly(.text("item:openThread"), forKey: "objectActions.status.longPress", account: "me@example.com")
        #expect(settings.statusActions.longPress == .item(.openThread))

        let tokens = Array(settings.postActionBarLayout.tokens.reversed())
        try settings.setDirectly(.list(tokens), forKey: AppSettings.Keys.postActionBarLayout, account: "me@example.com")
        #expect(settings.postActionBarLayout.tokens == tokens)

        try settings.setDirectly(.number(30), forKey: AppSettings.appearanceKey(AppearanceCatalog.rowPaddingTop), account: "me@example.com")
        #expect(settings.value(of: AppearanceCatalog.rowPaddingTop) == 30)
    }

    /// 設定の画面の行のキーは、場所と行の名前を付けて並び、書いた値が一覧に出る。
    @Test func listsItemsWithTheirPlace() throws {
        let settings = makeSettings()
        let key = AppSettings.Keys.usesOriginalThumbnailsOnExpensiveNetwork
        try settings.setDirectly(.bool(false), forKey: key, account: "me@example.com")

        let entry = try #require(settings.directEntries(account: "me@example.com").first { $0.key == key })
        #expect(entry.place == "表示 > メディア > 高画質のサムネイル")
        #expect(entry.value == .bool(false))
    }

    /// 対象の操作の画面のどのキーも、一覧に1回ずつ出る。
    @Test func listsEachKeyOnce() {
        let keys = makeSettings().directEntries(account: "me@example.com").map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys.contains("objectActions.status.tap"))
        #expect(keys.contains(AppSettings.Keys.postActionBarLayout))
    }

    /// 知らないキーと、アプリが読めない値は、書かずに失敗する。値を持っていないキーでも、範囲の外の数と知らない選択肢でも同じ。
    @Test func rejectsUnknownKeyAndUnreadableValues() throws {
        let settings = makeSettings()
        let account = "me@example.com"
        #expect(throws: SettingsDirectAccessError.unknownKey("nope")) {
            try settings.setDirectly(.bool(true), forKey: "nope", account: account)
        }
        let thumbnails = AppSettings.Keys.usesOriginalThumbnailsOnExpensiveNetwork
        #expect(throws: SettingsDirectAccessError.unreadable(key: thumbnails, value: .text("off"))) {
            try settings.setDirectly(.text("off"), forKey: thumbnails, account: account)
        }
        let avatarShape = AppearanceStorage.key(AppearanceChoice.avatarShape.field)
        #expect(throws: SettingsDirectAccessError.unreadable(key: avatarShape, value: .text("not-a-shape"))) {
            try settings.setDirectly(.text("not-a-shape"), forKey: avatarShape, account: account)
        }
        let padding = AppSettings.appearanceKey(AppearanceCatalog.rowPaddingTop)
        #expect(throws: SettingsDirectAccessError.unreadable(key: padding, value: .number(1000))) {
            try settings.setDirectly(.number(1000), forKey: padding, account: account)
        }
        #expect(throws: SettingsDirectAccessError.unreadable(key: "objectActions.status.tap", value: .text("item:nope"))) {
            try settings.setDirectly(.text("item:nope"), forKey: "objectActions.status.tap", account: account)
        }
        #expect(settings.usesOriginalThumbnailsOnExpensiveNetwork)
        #expect(settings.value(of: AppearanceCatalog.rowPaddingTop) == AppearanceCatalog.rowPaddingTop.defaultValue)
    }

    /// 一覧に出るどのキーも、アプリが読めない値を断る。読み方の分からないキーを、確かめずに書かないため。
    @Test func everyListedKeyRejectsUnreadableValue() {
        let settings = makeSettings()
        // 訳す言語と訳さない人のハンドルは、どんな文字列の列も値になるので、種類の違う値で確かめる。
        let freeLists = [AppSettings.autoTranslationLanguagesDirectKey, AppSettings.autoTranslationExcludedHandlesDirectKey]
        for entry in settings.directEntries(account: "me@example.com") {
            let unreadable: PresetValue = freeLists.contains(entry.key) ? .text("\u{1}") : .list(["\u{1}"])
            #expect(throws: SettingsDirectAccessError.self, "\(entry.key)") {
                try settings.setDirectly(unreadable, forKey: entry.key, account: "me@example.com")
            }
        }
    }

    /// 「アカウント設定に従う」を選べる真偽値は、真偽値とnullを行き来できる。
    @Test func switchesOptionalBoolAndNull() throws {
        let settings = makeSettings()
        let key = AppearanceStorage.key(AppearanceChoice.animatesAvatars.field)
        try settings.setDirectly(.bool(false), forKey: key, account: "me@example.com")
        #expect(settings.appearance.animatesAvatars == false)
        try settings.setDirectly(.null, forKey: key, account: "me@example.com")
        #expect(settings.appearance.animatesAvatars == nil)
    }

    /// タブの並びは、そのアカウントの並びに書き、知らない項目があれば書かない。
    @Test func writesTabLayoutOfTheAccount() throws {
        let settings = makeSettings()
        let tokens = ["item:home", "more", "item:notifications", "hidden:search"]
        try settings.setDirectly(.list(tokens), forKey: AppSettings.tabLayoutDirectKey, account: "me@example.com")
        #expect(Array(settings.tabLayout(for: "me@example.com").tokens.prefix(4)) == tokens)
        #expect(settings.tabLayout(for: "other@example.com") == TabItem.defaultLayout)

        #expect(throws: SettingsDirectAccessError.unknownTabItems(["item:nope"])) {
            try settings.setDirectly(.list(["item:home", "item:nope"]), forKey: AppSettings.tabLayoutDirectKey, account: "me@example.com")
        }
    }

    /// 自動翻訳の画面の、プリセットに含めない値も書け、知らない翻訳モードは書かない。
    @Test func writesAutoTranslationValuesOutsidePresets() throws {
        let settings = makeSettings()
        let account = "me@example.com"
        try settings.setDirectly(.list(["en", "ko"]), forKey: AppSettings.autoTranslationLanguagesDirectKey, account: account)
        try settings.setDirectly(.text("highFidelity"), forKey: AppSettings.autoTranslationStrategyDirectKey, account: account)
        #expect(settings.autoTranslationLanguages == ["en", "ko"])
        #expect(settings.autoTranslationStrategy == .highFidelity)
        #expect(throws: SettingsDirectAccessError.unreadable(key: AppSettings.autoTranslationStrategyDirectKey, value: .text("fast"))) {
            try settings.setDirectly(.text("fast"), forKey: AppSettings.autoTranslationStrategyDirectKey, account: account)
        }
    }

    /// JSONの値は、真偽値、数、文字列、文字列の配列、nullとして読み、ほかは読まない。
    @Test func readsJSONValues() throws {
        #expect(try PresetValue(json: "true") == .bool(true))
        #expect(try PresetValue(json: "1.5") == .number(1.5))
        #expect(try PresetValue(json: "\"a\"") == .text("a"))
        #expect(try PresetValue(json: "[\"a\",\"b\"]") == .list(["a", "b"]))
        #expect(try PresetValue(json: "null") == .null)
        #expect(throws: SettingsDirectAccessError.unreadableValue("{}")) { try PresetValue(json: "{}") }
    }
}
