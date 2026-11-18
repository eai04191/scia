import Foundation
import Testing
import SciaTesting
@testable import SciaCore

/// 設定の画面の行と画面に付ける、読んでいるプリセットが変えたかの点と、親のプリセットへ戻すこと（docs/preset.md）。
@Suite(.scratch)
@MainActor
struct SettingsModifiedTests {
    /// 「標準」を親にしたプリセットを読み書きする設定。
    private func makeSettings() throws -> AppSettings {
        let app = AppSettings(defaults: TestScratch.defaults("SettingsModifiedTests"))
        var home: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            home = try library.create(parent: .builtIn(.standard), name: "家")
        }
        return app.editing(home)
    }

    /// 行の値を変えると、その行と、その行を並べた分類の画面に点が付き、ほかの分類には付かない。
    @Test func itemMarksItsCategory() throws {
        let settings = try makeSettings()
        settings.accentColor = .purple

        #expect(settings.isModified(.accentColor))
        #expect(settings.isModified(.display))
        #expect(!settings.isModified(.interaction))
        #expect(!settings.isModified(.compose))

        settings.reset(.accentColor)
        #expect(!settings.isModified(.display))
    }

    /// 2つの値を変える行（投稿欄の出し方）は、どちらを変えても点が付き、戻すと両方とも親に従う。
    @Test func itemWithTwoValues() throws {
        let settings = try makeSettings()
        settings.composeBarIdle = .hidden

        #expect(settings.isModified(.composeBarIdle))
        settings.reset(.composeBarIdle)
        #expect(!settings.isModified(.composeBarIdle))
        #expect(!settings.isModified(.compose))
    }

    /// タップと長押しは別々に点を付けて戻せ、どちらも対象の画面と操作の分類に点を付ける。
    @Test func triggersAreMarkedSeparately() throws {
        let settings = try makeSettings()
        settings.statusActions.tap = .actionBar

        #expect(settings.isModified(.tap, on: .statusActions))
        #expect(!settings.isModified(.longPress, on: .statusActions))
        #expect(settings.isModified(.statusActions))
        #expect(settings.isModified(.interaction))

        settings.reset(.tap, on: .statusActions)
        #expect(!settings.isModified(.interaction))
    }

    /// 対象の画面の中の並び（アクションバー）を変えると、並びの画面、対象の画面、操作の分類に点が付く。
    @Test func nestedPageMarksParents() throws {
        let settings = try makeSettings()
        settings.postActionBarLayout = MenuLayout(tokens: ["item:reply"])

        #expect(settings.isModified(.statusActionBar))
        #expect(settings.isModified(.statusActions))
        #expect(settings.isModified(.interaction))
        #expect(!settings.isModified(.userActions))
    }

    /// 「投稿の見た目」の値は、表示の分類に点を付ける。分類を戻すと、中の画面の値もすべて親に従う。
    @Test func resettingCategoryResetsNestedPages() throws {
        let settings = try makeSettings()
        settings.appearance.showsTime = false
        settings.mediaDynamicRange = .high
        #expect(settings.isModified(.display))

        settings.reset(.display)

        #expect(!settings.isModified(.display))
        #expect(settings.appearance.showsTime)
        #expect(settings.mediaDynamicRange == .standard)
    }

    /// 自動翻訳の設定は1つずつ点を付けて戻せ、1つを戻してもほかの設定は変えたまま残る。
    @Test func autoTranslationSettingsResetIndependently() throws {
        let settings = try makeSettings()
        settings.autoTranslationTarget = "en"
        settings.autoTranslationLanguages = ["fr"]

        #expect(settings.isModified(AutoTranslationSetting.target))
        #expect(settings.isModified(AutoTranslationSetting.languages))
        #expect(!settings.isModified(AutoTranslationSetting.enabled))

        settings.reset(AutoTranslationSetting.target)

        #expect(settings.autoTranslationTarget == nil)
        #expect(settings.autoTranslationLanguages == ["fr"])
        #expect(settings.isModified(.autoTranslation))
    }

    /// プリセットに含めない値の行には、点を付けない。
    @Test func excludedItemIsNeverMarked() throws {
        let settings = try makeSettings()
        settings.ignoresUselessAltText = false
        #expect(!settings.isModified(.ignoresUselessAltText))
    }
}
