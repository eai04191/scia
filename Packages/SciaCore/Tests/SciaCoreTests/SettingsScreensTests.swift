import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// 設定の画面に何を、どの順で、どんな名前で並べるかの定義。どのUIもこの定義を描くので、行の漏れと行き先の食い違いを確かめる。
@Suite(.scratch)
@MainActor
struct SettingsScreensTests {
    private func pages(in sections: [SettingsSection]) -> [SettingsPage] {
        sections.flatMap(\.rows).compactMap { row in
            if case .page(let page) = row { page } else { nil }
        }
    }

    private func items(in sections: [SettingsSection]) -> [SettingsItem] {
        sections.flatMap(\.rows).compactMap { row in
            if case .item(let item) = row { item } else { nil }
        }
    }

    @Test func rootListsAccountSettingsUnderHandle() {
        let sections = SettingsPage.rootSections(handle: "@alice@example.social")

        #expect(sections.map(\.header) == ["@alice@example.social", nil, nil, nil, nil])
        #expect(sections.map { $0.rows.map(\.title) } == [["アカウント", "タブ"], ["アカウントを管理"], ["プリセット"], ["表示", "操作", "作成", "アプリのアイコン"], ["ストレージ", "情報"]])
    }

    /// 画面へ入る行は、`path`でその画面の1つ手前に重ねる画面にだけ並べる。食い違うと、URLで開いたときと行から入ったときで戻る先が変わる。
    @Test func pageRowsMatchPaths() throws {
        for page in pages(in: SettingsPage.rootSections(handle: "")) {
            #expect(page.path == [page], "\(page)")
        }
        for parent in SettingsPage.allCases {
            for child in pages(in: parent.sections ?? []) {
                #expect(child.path.dropLast().last == parent, "\(parent)に\(child)を並べています")
            }
        }
    }

    /// どの画面も、トップの画面からたどって開ける。並びを持つ画面の行か、対象の操作の画面、ストレージの画面の入り口にある。
    @Test func everyPageIsReachable() {
        var reachable = Set(pages(in: SettingsPage.rootSections(handle: "")))
        for page in SettingsPage.allCases {
            reachable.formUnion(pages(in: page.sections ?? []))
            if let screen = ObjectActionsScreen(page) {
                reachable.formUnion([screen.menu, screen.actionBar].compactMap(\.self) + screen.swipes.map(\.page))
            }
        }
        // 接続の状態とストレージは、値と一緒に並べる画面なので、入り口は画面の中にある。プリセットの選択と管理はプリセットの画面の行から、編集は管理の画面の行から、比較は管理の画面のメニューから開く。
        reachable.formUnion([.connectionTimelines, .viewedMediaCache, .prefetchedMediaCache, .presetManagement, .presetEditor, .presetComparison, .appPreset, .accountPreset])

        #expect(Set(SettingsPage.allCases).subtracting(reachable).isEmpty)
    }

    /// 項目は、どれか1つの画面にだけ並べる。
    @Test func everyItemIsListedOnce() {
        let listed = SettingsPage.allCases.flatMap { items(in: $0.sections ?? []) }

        #expect(listed.sorted { $0.rawValue < $1.rawValue } == SettingsItem.allCases.sorted { $0.rawValue < $1.rawValue })
    }

    /// 並びの画面へ入る行は、対象の画面の中では短く「メニュー」と書き、開いた画面の題では何のメニューかを書く。
    @Test func menuRowIsShortInsideObjectScreen() throws {
        let screen = try #require(ObjectActionsScreen(.userActions))
        let menu = try #require(screen.menu)

        #expect(menu.rowTitle == "メニュー")
        #expect(menu.title == "ユーザーのメニュー")
        #expect(screen.noMenuFooter() == "タップでも長押しでもメニューを開かないため、ユーザーのメニューにしかない操作は使えません。")
    }

    /// 投稿だけが、アクションバー、スワイプ、アクションバーを出している投稿のメニューの設定を持つ。引用の投稿と通知は、自分のメニューを持たない。
    @Test func onlyStatusScreenHasActionBarAndSwipes() throws {
        let status = try #require(ObjectActionsScreen(.statusActions))
        let quoted = try #require(ObjectActionsScreen(.quotedStatusActions))

        #expect(status.actionBar == .statusActionBar)
        #expect(status.swipes == [.leading, .trailing])
        #expect(status.toggles == [.actionBarItemsInMenu, .actionBarLongPressItemsInMenu])
        #expect(quoted.menu == nil && quoted.actionBar == nil && quoted.swipes.isEmpty && quoted.toggles.isEmpty)
        #expect(ObjectActionsScreen(.display) == nil)
    }

    /// 対象の名前は、その対象の操作の画面の題と同じ。
    @Test func objectEntityTitleIsItsScreenTitle() {
        #expect(ObjectEntity.status.title == SettingsPage.statusActions.title)
        #expect(ObjectEntity.externalPost.title == "ほかのサービスの投稿")
    }

    /// 先頭の側は、左から右へ書く言語では右にスワイプして出す。右から左へ書く言語では名前を入れ替える。
    @Test func swipeTitleFollowsLayoutDirection() {
        #expect(SettingsPage.statusLeadingSwipe.title(isRightToLeft: false) == "右にスワイプ")
        #expect(SettingsPage.statusLeadingSwipe.title(isRightToLeft: true) == "左にスワイプ")
        #expect(SettingsPage.statusTrailingSwipe.title(isRightToLeft: false) == "左にスワイプ")
    }

    @Test func swipeSummaryListsAssignedItems() {
        #expect(MenuLayout<PostSwipeItem>(tokens: []).swipeSummary == TextLists.ItemList(single: "なし"))
    }

    /// 選んで決める項目は、どれか1つの分類にだけ並べる。
    @Test func everyAppearanceChoiceBelongsToOneGroup() {
        let listed = AppearanceCatalog.groups.flatMap { AppearanceChoice.choices(inGroup: $0.id) }

        #expect(listed.count == AppearanceChoice.allCases.count)
        #expect(Set(listed) == Set(AppearanceChoice.allCases))
    }

    /// 選択肢は、並べた番号で読み書きする。選んだ値は設定に入る。
    @Test func appearanceOptionsReadAndWriteSettings() throws {
        let settings = AppSettings(defaults: TestScratch.defaults("SettingsScreensTests.options"))
        guard case .options(let options) = AppearanceChoice.avatarShape.control else {
            Issue.record("アイコンの形が、選択肢から選ぶ項目になっていません")
            return
        }
        #expect(options.titles == ["円", "四角"])
        #expect(options.selectedIndex(settings) == 1)

        options.select(0, settings)

        #expect(settings.appearance.avatarShape == .circle)
        #expect(options.selectedIndex(settings) == 0)
    }

    /// 選んで決める項目は、部品で変えると、その項目だけが既定から変わったことになり、戻すと既定の値に戻る。
    @Test(arguments: AppearanceChoice.allCases)
    func changedChoiceIsModifiedUntilReset(_ choice: AppearanceChoice) {
        let settings = AppSettings(defaults: TestScratch.defaults("SettingsScreensTests.modified.\(choice)"))
        #expect(!settings.isModified(choice))

        switch choice.control {
        case .toggle(let keyPath): settings[keyPath: keyPath].toggle()
        case .options(let options): options.select(options.selectedIndex(settings) == 0 ? 1 : 0, settings)
        }

        #expect(AppearanceChoice.allCases.filter(settings.isModified) == [choice])
        #expect(settings.isAppearanceModified)

        settings.reset(choice)

        #expect(settings.appearance == AppearanceChoices())
    }

    /// 分類は、選んで決める項目だけを変えても、変わったことになる。
    @Test func groupIsModifiedByChoiceAlone() throws {
        let settings = AppSettings(defaults: TestScratch.defaults("SettingsScreensTests.modifiedGroup"))
        let body = try #require(AppearanceCatalog.groups.first { $0.id == "body" })
        let media = try #require(AppearanceCatalog.groups.first { $0.id == "media" })

        settings.appearance.showsBody = false

        #expect(settings.isAppearanceGroupModified(body))
        #expect(!settings.isAppearanceGroupModified(media))
    }

    /// アニメーションを再生するかは、「アカウント設定に従う」「オン」「オフ」から選び、既定は「アカウント設定に従う」。
    /// 選んだあとに「アカウント設定に従う」へ戻せる（docs/preset.md）。
    @Test func animationChoiceFollowsAccountUntilChosen() {
        let settings = AppSettings(defaults: TestScratch.defaults("SettingsScreensTests.animations"))
        guard case .options(let options) = AppearanceChoice.animatesAvatars.control else {
            Issue.record("アイコンのアニメーションが、選ぶメニューになっていません")
            return
        }
        #expect(options.titles == ["アカウント設定に従う", "オン", "オフ"])
        #expect(options.selectedIndex(settings) == 0)

        options.select(2, settings)
        #expect(settings.appearance.animatesAvatars == false)
        options.select(0, settings)
        #expect(settings.appearance.animatesAvatars == nil)
        #expect(options.selectedIndex(settings) == 0)
    }

    /// ほかの選択のために見た目に効かない項目は、変えられなくする。
    @Test func choicesWithoutEffectAreDisabled() {
        var appearance = AppearanceChoices()
        #expect(AppearanceChoice.showsReplyLines.isEnabled(in: appearance))
        #expect(AppearanceChoice.linkCardThumbnailSide.isEnabled(in: appearance))

        appearance.wrapsBelowAvatar = true
        appearance.showsLinkCardImage = false
        appearance.statusNameStyle = .nameOnly

        #expect(!AppearanceChoice.showsReplyLines.isEnabled(in: appearance))
        #expect(!AppearanceChoice.linkCardThumbnailSide.isEnabled(in: appearance))
        #expect(!AppearanceChoice.stacksNameParts.isEnabled(in: appearance))
        #expect(!AppearanceCatalog.isUsed(AppearanceCatalog.reactionGlowIconSize, in: appearance))
    }

    /// 違和感レポートは、残っていないときは内訳にも消すボタンにも出さない。ほかの項目は、空でも出す。
    @Test func emptyDiscomfortReportsAreHidden() {
        #expect(!StorageBreakdown.Category.discomfortReports.isShown(bytes: 0))
        #expect(StorageBreakdown.Category.discomfortReports.isShown(bytes: 1))
        #expect(StorageBreakdown.Category.discomfortReports.isShown(bytes: nil))
        #expect(StorageBreakdown.Category.networkCache.isShown(bytes: 0))
    }
}
