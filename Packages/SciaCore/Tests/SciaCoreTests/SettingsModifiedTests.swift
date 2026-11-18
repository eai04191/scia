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
        settings.isAutoTranslationEnabled = true

        #expect(settings.isModified(AutoTranslationSetting.target))
        #expect(settings.isModified(AutoTranslationSetting.enabled))

        settings.reset(AutoTranslationSetting.target)

        #expect(settings.autoTranslationTarget == nil)
        #expect(settings.isAutoTranslationEnabled)
        #expect(settings.isModified(.autoTranslation))
    }

    /// 訳す言語と翻訳モードはプリセットに含めない。プリセットを替えても変わらず、変えても点を付けない。
    @Test func autoTranslationLanguagesAndStrategyStayOutOfPresets() throws {
        let settings = AppSettings(defaults: TestScratch.defaults("SettingsModifiedTests.translation"))
        settings.autoTranslationLanguages = ["fr"]
        settings.autoTranslationStrategy = .highFidelity

        try settings.store.tryUpdateLibrary { library throws(PresetError) in try library.select(.builtIn(.compact), for: .app) }

        #expect(settings.autoTranslationLanguages == ["fr"])
        #expect(settings.autoTranslationStrategy == .highFidelity)
        #expect(settings.presetID == .builtIn(.compact))
        #expect(!settings.isModified(.autoTranslation))
    }

    /// 組み込みのプリセットの値は、どれも設定の画面の行か画面からたどれるキーで、範囲の中の値を持つ。
    /// たどれないキーや範囲の外の値は、選んでも効かないか、設定の画面で戻せないため。
    @Test(arguments: BuiltInPreset.allCases)
    func builtInValuesAreReachable(_ preset: BuiltInPreset) throws {
        let reachable = Set([SettingsPage.display, .interaction, .compose].flatMap(AppSettings.keys(of:)))
        for key in preset.values.keys {
            #expect(reachable.contains(key), "\(preset)の\(key)")
        }
        let app = AppSettings(defaults: TestScratch.defaults("SettingsModifiedTests.builtIn"))
        try app.store.tryUpdateLibrary { library throws(PresetError) in try library.select(.builtIn(preset), for: .app) }
        for item in AppearanceCatalog.values where preset.values["appearanceValue.\(item.id)"] != nil {
            guard case .number(let number) = preset.values["appearanceValue.\(item.id)"] else { continue }
            #expect(item.range.contains(number), "\(preset)の\(item.id)")
            #expect(app.value(of: item) == number)
        }
    }

    /// 比べる項目は、プリセットに含める値をすべて、重ならずに持つ。プリセットに含める値を足して比較に足し忘れると落ちる。
    @Test func comparisonCoversEveryPresetKey() {
        let catalog = PresetComparison.catalog(languageName: { $0 }, deviceLanguageName: "日本語")
        let compared = catalog.flatMap(\.entries).flatMap(\.keys)
        let presetKeys = Set([SettingsPage.display, .interaction, .compose].flatMap(AppSettings.keys(of:)))
        #expect(Set(compared) == presetKeys)
        #expect(compared.count == Set(compared).count)
    }

    /// 組み込みのプリセットが持つ値は、どれも標準との比較に出る。既定値と同じ値を足すと落ちる。
    @Test(arguments: BuiltInPreset.allCases)
    func builtInValuesAppearInComparison(_ preset: BuiltInPreset) {
        let settings = AppSettings(defaults: TestScratch.defaults("SettingsModifiedTests.comparison"))
        let comparison = PresetComparison(base: settings.editing(.builtIn(.standard)), compared: settings.editing(.builtIn(preset)), languageName: { $0 }, deviceLanguageName: "日本語")
        let shown = Set(comparison.sections.flatMap(\.rows).flatMap(\.keys))
        #expect(shown == Set(preset.values.keys))
    }

    /// 並びは、項目の名前、非表示、区切り線、境目を並びのとおりに読み、違えば比較に出す。
    @Test func comparisonShowsLayoutDifference() throws {
        let settings = AppSettings(defaults: TestScratch.defaults("SettingsModifiedTests.layout"))
        settings.composeToolLayout = MenuLayout(elements: Array(settings.composeToolLayout.elements.reversed()))
        let comparison = PresetComparison(base: settings.editing(.builtIn(.standard)), compared: settings, languageName: { $0 }, deviceLanguageName: "日本語")
        let row = try #require(comparison.sections.flatMap(\.rows).first)
        #expect(row.keys == [AppSettings.Keys.composeToolLayout])
        guard case .layout(let base) = row.base, case .layout(let compared) = row.compared else {
            Issue.record("並びとして読んでいない")
            return
        }
        #expect(compared == base.reversed())
    }

    /// 比べるための2つの使う人のプリセット。どちらも標準を親にする。
    private func comparedPresets(_ name: String) throws -> (AppSettings, AppSettings) {
        let settings = AppSettings(defaults: TestScratch.defaults("SettingsModifiedTests.\(name)"))
        var ids: [PresetID] = []
        try settings.store.tryUpdateLibrary { library throws(PresetError) in
            ids = [try library.create(parent: .builtIn(.standard), name: "A"), try library.create(parent: .builtIn(.standard), name: "B")]
        }
        return (settings.editing(ids[0]), settings.editing(ids[1]))
    }

    private func comparison(_ base: AppSettings, _ compared: AppSettings) -> [PresetComparison.Row] {
        PresetComparison(base: base, compared: compared, languageName: { $0 }, deviceLanguageName: "日本語").sections.flatMap(\.rows)
    }

    /// 刻みが0.05の値は、小数点以下2桁まで書いて比べる。丸めて同じに見える値（0.75と0.8）も、違う項目として出す。
    @Test func comparisonKeepsFinerSteps() throws {
        let (base, compared) = try comparedPresets("steps")
        compared.setValue(0.8, for: AppearanceCatalog.mediaTallestAspectRatio)
        let row = try #require(comparison(base, compared).first)
        #expect(row.base == .text(TextLists.ItemList(single: "0.75")))
        #expect(row.compared == .text(TextLists.ItemList(single: "0.80")))
    }

    /// 横並びの大きさだけが違う並びも、違う項目として出す。
    @Test func comparisonKeepsRowSeparatorSize() throws {
        let (base, compared) = try comparedPresets("rowSize")
        let elements = compared.statusMenuLayout.elements
        let index = try #require(elements.firstIndex { if case .rowSeparator(.medium) = $0 { true } else { false } })
        var changed = elements
        changed[index] = .rowSeparator(.small)
        compared.statusMenuLayout = MenuLayout(elements: changed)
        let rows = comparison(base, compared)
        #expect(rows.map(\.keys) == [[AppSettings.Keys.statusMenuLayout]])
    }

    /// 全画面で開く設定どうしでも、つまみを下げたときの高さが違えば、違う項目として出す。
    @Test func comparisonKeepsInAppBrowserHeightWhenFullScreen() throws {
        let (base, compared) = try comparedPresets("browser")
        base.opensInAppBrowserFullScreen = true
        compared.opensInAppBrowserFullScreen = true
        compared.inAppBrowserHeight = InAppBrowserHeight(spaceAbove: base.inAppBrowserHeight.spaceAbove + 80)
        let rows = comparison(base, compared)
        #expect(rows.map(\.keys) == [AppSettings.keys(of: .inAppBrowserHeight)])
    }

    /// 見出しが同じになる節（リンクの対象の操作と、操作の画面の「リンク」の節）も、別の節として見分けられる。
    @Test func comparisonSectionsHaveDistinctIDs() throws {
        let (base, compared) = try comparedPresets("sectionIDs")
        compared.linkActions = ObjectActions(tap: .menu, longPress: .menu)
        compared.linkBrowser = LinkBrowser.allCases.first { $0 != base.linkBrowser } ?? base.linkBrowser
        let sections = PresetComparison(base: base, compared: compared, languageName: { $0 }, deviceLanguageName: "日本語").sections
        #expect(sections.count == 2)
        #expect(Set(sections.map(\.id)).count == sections.count)
    }

    /// コンパクトは、アクションバーを常には出さず、タップで開く。
    @Test func compactOpensActionBarByTap() throws {
        let app = AppSettings(defaults: TestScratch.defaults("SettingsModifiedTests.compact"))
        try app.store.tryUpdateLibrary { library throws(PresetError) in try library.select(.builtIn(.compact), for: .app) }
        #expect(!app.appearance.showsActionBar)
        #expect(app.statusActions.tap == .actionBar)
    }

    /// プリセットに含めない値の行には、点を付けない。
    @Test func excludedItemIsNeverMarked() throws {
        let settings = try makeSettings()
        settings.ignoresUselessAltText = false
        #expect(!settings.isModified(.ignoresUselessAltText))
    }
}
