import Foundation
import Observation
import Testing
import SciaTesting
@testable import SciaCore

/// 設定の値を、アプリとアカウントが使うプリセットから読み書きする（docs/preset.md）。
@Suite(.scratch)
@MainActor
struct AppSettingsPresetTests {
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: TestScratch.defaults("AppSettingsPresetTests"))
    }

    /// 組み込みのプリセットを使っているときに値を変えると、「標準 2」を作ってアプリをそちらに切り替える。割り当てていないアカウントも、その値を読む。
    @Test func editingBuiltInCreatesPresetForApp() {
        let app = makeSettings()
        let account = app.forAccount("a@example.social")

        app.linkBrowser = .external

        #expect(app.presetID == .user(1))
        #expect(app.store.library.name(of: app.presetID) == "標準 2")
        #expect(account.presetID == .user(1))
        #expect(account.linkBrowser == .external)
    }

    /// 組み込みのプリセットから作って切り替えたときだけ、作ったプリセットを知らせる。作ったあとの値の変更では知らせない。
    @Test func reportsCreatedPresetOnlyWhenSwitching() {
        let app = makeSettings()
        let account = app.forAccount("a@example.social")
        var created: [PresetID] = []
        account.onPresetCreated = { created.append($0) }

        account.linkBrowser = .external
        account.linkBrowser = .inApp

        #expect(created == [.user(1)])
    }

    /// アカウントにプリセットを割り当てると、そのアカウントの設定だけがそのプリセットを読み、アプリの設定は変わらない。
    @Test func accountReadsAssignedPreset() throws {
        let app = makeSettings()
        let a = app.forAccount("a@example.social")
        let b = app.forAccount("b@example.social")
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            let outside = try library.create(parent: .builtIn(.standard), name: "外")
            try library.setValue(.text("external"), forKey: AppSettings.Keys.linkBrowser, in: outside)
            try library.select(outside, for: .account("a@example.social"))
        }

        #expect(a.linkBrowser == .external)
        #expect(b.linkBrowser == .inApp)
        #expect(app.linkBrowser == .inApp)

        // アカウントの設定で変えた値は、割り当てたプリセットに入り、アプリのプリセットには入らない。
        a.accentColor = .purple
        #expect(a.store.library.value(forKey: AppSettings.Keys.accentColor, in: a.presetID) == .text("purple"))
        #expect(app.accentColor == .blue)
    }

    /// 決まったプリセットを開いた設定は、アプリやアカウントが使っていなくても、そのプリセットを読み書きする。
    @Test func editingSpecificPresetDoesNotSwitch() throws {
        let app = makeSettings()
        var home: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            home = try library.create(parent: .builtIn(.standard), name: "家")
        }
        let editor = app.editing(home)

        editor.mediaDynamicRange = .high

        #expect(editor.mediaDynamicRange == .high)
        #expect(app.mediaDynamicRange == .standard)
        #expect(app.presetID == .builtIn(.standard))
    }

    /// 「投稿の見た目」の選択肢は、選択肢ごとに変えた項目になる。1つを変えても、ほかの選択肢は親の値に従い続ける。
    @Test func appearanceChoicesAreInheritedPerChoice() throws {
        let app = makeSettings()
        var base: PresetID = .builtIn(.standard)
        var home: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            base = try library.create(parent: .builtIn(.standard), name: "自分用")
            home = try library.create(parent: base, name: "家")
        }
        let baseSettings = app.editing(base)
        let homeSettings = app.editing(home)

        homeSettings.appearance.showsTime = false
        baseSettings.appearance.avatarShape = .circle

        #expect(homeSettings.isModified(.showsTime))
        #expect(!homeSettings.isModified(.avatarShape))
        #expect(homeSettings.appearance.avatarShape == .circle)
        #expect(homeSettings.appearance.showsTime == false)
    }

    /// 親と同じ値にしても変えた項目のまま残り、親がそのあと変わっても子は変わらない。戻すと親に従う。
    @Test func appearanceValueEqualToParentStaysModified() throws {
        let app = makeSettings()
        var base: PresetID = .builtIn(.standard)
        var home: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            base = try library.create(parent: .builtIn(.standard), name: "自分用")
            home = try library.create(parent: base, name: "家")
        }
        let item = AppearanceCatalog.bodyText
        let homeSettings = app.editing(home)
        homeSettings.setValue(item.defaultValue, for: item)
        #expect(homeSettings.isModified(item))

        app.editing(base).setValue(item.defaultValue + item.step, for: item)
        #expect(homeSettings.value(of: item) == item.defaultValue)

        homeSettings.reset([item])
        #expect(!homeSettings.isModified(item))
        #expect(homeSettings.value(of: item) == item.defaultValue + item.step)
    }

    /// タップと長押しは別々の値で、子がタップだけを変えたら、長押しは親の変更に従う。
    @Test func tapAndLongPressAreInheritedSeparately() throws {
        let app = makeSettings()
        var base: PresetID = .builtIn(.standard)
        var home: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            base = try library.create(parent: .builtIn(.standard), name: "自分用")
            home = try library.create(parent: base, name: "家")
        }
        let homeSettings = app.editing(home)
        homeSettings.statusActions.tap = .actionBar
        app.editing(base).statusActions.longPress = .item(.favourite)

        #expect(homeSettings.statusActions == ObjectActions(tap: .actionBar, longPress: .item(.favourite)))
    }

    /// 子で、親から受け継いでいる操作を選び直すと、子の値として持つ。あとで親の操作を変えても、選んだ操作は変わらない。
    @Test func selectingInheritedActionPinsIt() throws {
        let app = makeSettings()
        var base: PresetID = .builtIn(.standard)
        var home: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            base = try library.create(parent: .builtIn(.standard), name: "自分用")
            home = try library.create(parent: base, name: "家")
        }
        let homeSettings = app.editing(home)
        let inherited = homeSettings.statusActions.tap

        homeSettings.select(inherited, for: .tap, on: .statusActions)
        app.editing(base).statusActions.tap = .actionBar

        #expect(homeSettings.isModified(.tap, on: .statusActions))
        #expect(homeSettings.statusActions.tap == inherited)
    }

    /// 「アカウント設定に従う」は値の1つで、親がオンにしていても、子で選べる。選ぶと、そのアカウントのサーバーの値に従う。
    @Test func followsAccountSettingOverridesParent() throws {
        let app = makeSettings()
        var base: PresetID = .builtIn(.standard)
        var home: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            base = try library.create(parent: .builtIn(.standard), name: "自分用")
            home = try library.create(parent: base, name: "家")
            try library.select(home, for: .account("a@example.social"))
        }
        app.editing(base).appearance.animatesAvatars = true
        let account = app.forAccount("a@example.social")
        #expect(account.animatesAvatars)

        app.editing(home).appearance.animatesAvatars = nil
        app.rememberServerAnimations(false, of: "a@example.social")

        #expect(account.appearance.animatesAvatars == nil)
        #expect(!account.animatesAvatars)
        #expect(app.editing(home).isModified(.animatesAvatars))
    }

    /// メニューで選んだ選択肢は、親から受け継いだ値と同じでも、そのプリセットの値として持つ。あとで親を変えても、選んだ値のまま残る。
    @Test func choosingInheritedOptionPinsIt() throws {
        let app = makeSettings()
        var base: PresetID = .builtIn(.standard)
        var home: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            base = try library.create(parent: .builtIn(.standard), name: "自分用")
            home = try library.create(parent: base, name: "家")
        }
        let homeSettings = app.editing(home)
        guard case .options(let options) = AppearanceChoice.animatesAvatars.control else {
            Issue.record("アイコンのアニメーションが、選ぶメニューになっていません")
            return
        }

        options.select(0, homeSettings)
        app.editing(base).appearance.animatesAvatars = true

        #expect(homeSettings.isModified(.animatesAvatars))
        #expect(homeSettings.appearance.animatesAvatars == nil)
    }

    /// サーバーの「アニメーションGIFを自動再生する」は、アカウントの設定ごとに、そのアカウントのキャッシュした値を読む。ウィンドウを分けて別のアカウントを開いていても混ざらない。
    @Test func serverAnimationsArePerAccount() {
        let app = makeSettings()
        let a = app.forAccount("a@example.social")
        let b = app.forAccount("b@example.social")
        app.rememberServerAnimations(true, of: "a@example.social")
        app.rememberServerAnimations(false, of: "b@example.social")

        #expect(a.animatesCustomEmojis)
        #expect(!b.animatesCustomEmojis)
    }

    /// プリセットに含めない値は、プリセットを切り替えても変わらない。
    @Test func excludedValuesSurvivePresetSwitch() throws {
        let app = makeSettings()
        app.emojiSkinTone = .dark
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            let home = try library.create(parent: .builtIn(.standard), name: "家")
            try library.select(home, for: .app)
        }
        #expect(app.emojiSkinTone == .dark)
        #expect(app.store.library.userPresets.allSatisfy { $0.values.isEmpty })
    }

    /// プリセットを切り替えると、アカウントの設定を読んでいる画面に変更が届く。
    @Test func switchingPresetNotifiesObservers() throws {
        let app = makeSettings()
        let account = app.forAccount("a@example.social")
        var home: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            home = try library.create(parent: .builtIn(.standard), name: "家")
            try library.setValue(.bool(false), forKey: AppearanceStorage.key("showsMedia"), in: home)
        }
        let changed = Gate()
        withObservationTracking {
            _ = account.appearance.showsMedia
        } onChange: {
            changed.open()
        }

        try app.store.tryUpdateLibrary { library throws(PresetError) in
            try library.select(home, for: .account("a@example.social"))
        }

        #expect(changed.isOpen)
        #expect(!account.appearance.showsMedia)
    }

    /// 値を変えても、ほかの値だけを読んでいる画面には変更が届かない。翻訳の言語を読む処理が、アクセントカラーを変えただけで翻訳をやり直さないため。
    @Test func changingOneValueDoesNotNotifyOthers() throws {
        let app = makeSettings()
        let account = app.forAccount("a@example.social")
        app.accentColor = .purple
        let changed = Gate()
        withObservationTracking {
            _ = account.effectiveAutoTranslationLanguages
            _ = account.appearance.showsMedia
            _ = account.value(of: AppearanceCatalog.bodyText)
        } onChange: {
            changed.open()
        }

        app.accentColor = .indigo
        app.linkBrowser = .external

        #expect(!changed.isOpen)
    }

    /// 使っていないプリセットの値を変えても、同じ値をほかのプリセットで読んでいる画面には届かない。プリセットを管理から直している間に、タイムラインを再描画したり翻訳をやり直したりしないため。
    @Test func changingUnusedPresetDoesNotNotifyOtherReaders() throws {
        let app = makeSettings()
        app.accentColor = .purple
        var unused: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            unused = try library.create(parent: .builtIn(.standard), name: "外")
        }
        let account = app.forAccount("a@example.social")
        let changed = Gate()
        withObservationTracking {
            _ = account.accentColor
            _ = account.isAutoTranslationEnabled
        } onChange: {
            changed.open()
        }

        let editing = app.editing(unused)
        editing.accentColor = .indigo
        editing.isAutoTranslationEnabled = true

        #expect(!changed.isOpen)
    }

    /// 親のプリセットの値を変えると、その値を受け継ぐ子を使う画面に届く。
    @Test func changingParentValueNotifiesChildReaders() throws {
        let app = makeSettings()
        var parent: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            parent = try library.create(parent: .builtIn(.standard), name: "親")
            let child = try library.create(parent: parent, name: "子")
            try library.select(child, for: .app)
        }
        let changed = Gate()
        withObservationTracking {
            _ = app.accentColor
        } onChange: {
            changed.open()
        }

        app.editing(parent).accentColor = .indigo

        #expect(changed.isOpen)
        #expect(app.accentColor == .indigo)
    }

    /// プリセットの中身を変えると、そのプリセットのその値を読んでいる画面に届く。
    @Test func changingValueNotifiesReaders() throws {
        let app = makeSettings()
        app.accentColor = .purple
        let account = app.forAccount("a@example.social")
        let changed = Gate()
        withObservationTracking {
            _ = account.accentColor
        } onChange: {
            changed.open()
        }

        app.accentColor = .indigo

        #expect(changed.isOpen)
    }

    /// 親のプリセットを消すと、子を使うアカウントの値をたどる道が変わるので、値を読んでいる画面に届く。値そのものは変わらない。
    @Test func deletingParentNotifiesReaders() throws {
        let app = makeSettings()
        var base: PresetID = .builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            base = try library.create(parent: .builtIn(.standard), name: "自分用")
            try library.setValue(.text("purple"), forKey: AppSettings.Keys.accentColor, in: base)
            let home = try library.create(parent: base, name: "家")
            try library.select(home, for: .account("a@example.social"))
        }
        let account = app.forAccount("a@example.social")
        let changed = Gate()
        withObservationTracking {
            _ = account.accentColor
        } onChange: {
            changed.open()
        }

        try app.store.tryUpdateLibrary { library throws(PresetError) in try library.delete(base) }

        #expect(changed.isOpen)
        #expect(account.accentColor == .purple)
    }

    /// どれかのプリセットが使う絵文字の種類を、使っていないプリセットの分も含めて並べる。
    @Test func emojiStylesInPresetsIncludesUnusedPresets() throws {
        let app = makeSettings()
        #expect(app.store.emojiStylesInPresets == [.system])
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            let home = try library.create(parent: .builtIn(.standard), name: "家")
            try library.setValue(.text(EmojiStyle.twemoji.rawValue), forKey: AppearanceStorage.key("emojiStyle"), in: home)
        }
        #expect(app.presetID == .builtIn(.standard))
        #expect(app.store.emojiStylesInPresets == [.system, .twemoji])
    }

    /// アカウントに割り当てたプリセットの絵文字の種類のうち、アプリのプリセットと違うものを並べる。使っていないプリセットの種類は並べない。
    @Test func accountEmojiStylesListsAssignedDifferentStyles() throws {
        let app = makeSettings()
        #expect(app.store.accountEmojiStyles.isEmpty)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            let twemoji = try library.create(parent: .builtIn(.standard), name: "twemoji")
            try library.setValue(.text(EmojiStyle.twemoji.rawValue), forKey: AppearanceStorage.key("emojiStyle"), in: twemoji)
            _ = try library.create(parent: twemoji, name: "使っていない")
            try library.select(.builtIn(.standard), for: .account("a@example.social"))
        }
        #expect(app.store.accountEmojiStyles.isEmpty)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            try library.select(.user(1), for: .account("b@example.social"))
        }
        #expect(app.store.accountEmojiStyles == [.twemoji])
    }

    /// 書いた値は保存し、起動し直しても読める。
    @Test func persistsPresets() throws {
        let defaults = TestScratch.defaults("AppSettingsPresetTests")
        let settings = AppSettings(defaults: defaults)
        settings.forAccount("a@example.social").postActionBarLayout = MenuLayout(tokens: ["item:reply"])
        settings.appearance.showsTime = false

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.appearance.showsTime == false)
        #expect(relaunched.forAccount("a@example.social").postActionBarLayout == MenuLayout(tokens: ["item:reply"]))
    }

    /// ログアウトしたアカウントの割り当てを忘れる。
    @Test func forgetsAccountAssignment() throws {
        let app = makeSettings()
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            let home = try library.create(parent: .builtIn(.standard), name: "家")
            try library.select(home, for: .account("a@example.social"))
        }
        app.forgetAccount("a@example.social")
        #expect(app.store.library.accountPresets.isEmpty)
    }

    /// 選択肢の名前は、どれも`AppearanceChoices`のプロパティを指す。指さない選択肢は、変えた項目にならず戻せないため。
    @Test func everyChoiceHasField() {
        for choice in AppearanceChoice.allCases {
            #expect(AppearanceStorage.fieldNames.contains(choice.field), "\(choice)")
        }
    }
    /// 同じ対象を開く設定を先に読んでいても、割り当て・解除・再選択のたびに現在の値を読む。
    @Test func cachedReadersFollowRepeatedSelections() throws {
        let app = makeSettings()
        app.accentColor = .purple
        let first = app.forAccount("a@example.social")
        let second = app.forAccount("a@example.social")
        let fixed = app.editing(app.presetID)
        #expect(first.accentColor == .purple)
        #expect(second.accentColor == .purple)
        #expect(fixed.accentColor == .purple)

        for _ in 0..<3 {
            let changed = Gate()
            let fixedChanged = Gate()
            withObservationTracking { _ = first.accentColor } onChange: { changed.open() }
            withObservationTracking { _ = fixed.accentColor } onChange: { fixedChanged.open() }
            try app.store.tryUpdateLibrary { library throws(PresetError) in
                try library.select(.builtIn(.standard), for: .account("a@example.social"))
            }
            #expect(changed.isOpen)
            #expect(!fixedChanged.isOpen)
            #expect(first.accentColor == .blue)
            #expect(second.accentColor == .blue)
            #expect(fixed.accentColor == .purple)

            let unassigned = Gate()
            withObservationTracking { _ = second.accentColor } onChange: { unassigned.open() }
            app.store.updateLibrary { $0.unassign(account: "a@example.social") }
            #expect(unassigned.isOpen)
            #expect(first.accentColor == .purple)
            #expect(second.accentColor == .purple)
        }
    }

    /// 値がない状態もキャッシュする。親へ値を追加してからリセットし、親を削除しても古い値を返さない。
    @Test func cachedMissingValueFollowsParentEditsAndDeletion() throws {
        let app = makeSettings()
        var parent = PresetID.builtIn(.standard)
        var child = PresetID.builtIn(.standard)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            parent = try library.create(parent: .builtIn(.standard), name: "親")
            child = try library.create(parent: parent, name: "子")
            try library.select(child, for: .app)
        }
        let editor = app.editing(parent)
        let fixed = app.editing(child)
        let item = AppearanceCatalog.bodyText
        #expect(app.value(of: item) == item.defaultValue)
        #expect(fixed.value(of: item) == item.defaultValue)
        for value in [2.0, 3.0] {
            let changed = Gate()
            withObservationTracking { _ = fixed.value(of: item) } onChange: { changed.open() }
            editor.setValue(value, for: item)
            #expect(changed.isOpen)
            #expect(app.value(of: item) == value)
            #expect(fixed.value(of: item) == value)
            editor.reset([item])
            #expect(app.value(of: item) == item.defaultValue)
            #expect(fixed.value(of: item) == item.defaultValue)
        }
        editor.setValue(4, for: item)
        #expect(app.value(of: item) == 4)
        #expect(fixed.value(of: item) == 4)
        try app.store.tryUpdateLibrary { library throws(PresetError) in try library.delete(parent) }
        #expect(app.value(of: item) == 4)
        #expect(fixed.value(of: item) == 4)
        fixed.reset([item])
        #expect(app.value(of: item) == item.defaultValue)
        #expect(fixed.value(of: item) == item.defaultValue)
    }

    /// 選び直したあとで再購読した読者には、前に使っていたプリセットの編集は届かない。
    @Test func cachedReaderStopsObservingPreviousPreset() throws {
        let app = makeSettings()
        app.accentColor = .purple
        let oldPreset = app.editing(app.presetID)
        let account = app.forAccount("a@example.social")
        #expect(account.accentColor == .purple)
        try app.store.tryUpdateLibrary { library throws(PresetError) in
            try library.select(.builtIn(.standard), for: .account("a@example.social"))
        }
        let changed = Gate()
        withObservationTracking { _ = account.accentColor } onChange: { changed.open() }
        oldPreset.accentColor = .indigo
        #expect(!changed.isOpen)
        #expect(account.accentColor == .blue)
    }

}
