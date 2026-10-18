import Foundation
import Testing
@testable import SciaCore

/// 既定で「その他」のすぐ後ろにある項目を持つ、テスト用のメニュー。
private enum TestMenuItem: String, MenuItemKind {
    case a
    case b
    case c
    case hiddenByDefault
    case delete

    static let defaultLayout = MenuLayout<TestMenuItem>(defaultElements: [
        .item(.a, isVisible: true),
        .item(.b, isVisible: true),
        .separator,
        .item(.c, isVisible: true),
        .item(.hiddenByDefault, isVisible: false),
        .more,
        .item(.delete, isVisible: true),
    ])
}

@MainActor
struct MenuLayoutTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "MenuLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func groupsSplitBySeparatorAndMore() {
        let groups = TestMenuItem.defaultLayout.groups

        #expect(groups.main == [[.a, .b], [.c]])
        #expect(groups.more == [[.delete]])
    }

    /// 非表示の項目を除いた結果、空になったまとまりは出さない。区切り線が続いても空のまとまりを作らない。
    @Test func emptyGroupsAreDropped() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .separator,
            .item(.a, isVisible: false),
            .separator,
            .separator,
            .item(.b, isVisible: true),
            .item(.c, isVisible: true),
            .item(.hiddenByDefault, isVisible: false),
            .more,
            .item(.delete, isVisible: false),
        ])

        #expect(layout.groups.main == [[.b, .c]])
        #expect(layout.groups.more == [])
    }

    @Test func tokensRoundTripIncludingHiddenItemsAndSeparators() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .item(.delete, isVisible: true),
            .separator,
            .item(.c, isVisible: false),
            .more,
            .item(.a, isVisible: true),
            .separator,
            .item(.b, isVisible: true),
            .item(.hiddenByDefault, isVisible: true),
        ])

        #expect(MenuLayout<TestMenuItem>(tokens: layout.tokens) == layout)
    }

    /// 新しい項目は、既定で直前にある項目の、保存した並びでの位置の後ろに入る。動かした項目についていく。
    @Test func newItemFollowsItsDefaultPredecessor() {
        let saved = ["item:c", "separator", "item:a", "hidden:hiddenByDefault", "more", "item:delete"]

        let layout = MenuLayout<TestMenuItem>(tokens: saved)

        #expect(layout.elements == [
            .item(.c, isVisible: true),
            .separator,
            .item(.a, isVisible: true),
            .item(.b, isVisible: true),
            .item(.hiddenByDefault, isVisible: false),
            .more,
            .item(.delete, isVisible: true),
        ])
    }

    /// 区切り線は目印にしない。既定で区切り線の直後にある項目は、その前の項目の後ろに入る。
    @Test func separatorsAreNotAnchors() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:b", "item:a", "separator", "hidden:hiddenByDefault", "more", "item:delete"])

        #expect(layout.elements.prefix(3) == [.item(.b, isVisible: true), .item(.c, isVisible: true), .item(.a, isVisible: true)])
    }

    /// 既定で「その他」のすぐ後ろにある項目は、保存した並びでも「その他」の中の先頭に入る。
    @Test func newItemAfterMoreGoesIntoMore() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:a", "more", "item:b", "item:c", "hidden:hiddenByDefault"])

        #expect(layout.groups.main == [[.a]])
        #expect(layout.groups.more == [[.delete, .b, .c]])
    }

    /// 新しい項目の表示は、項目ごとの既定に従う。
    @Test func newItemTakesDefaultVisibility() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:a", "item:b", "item:c", "more", "item:delete"])

        #expect(layout.elements.contains(.item(.hiddenByDefault, isVisible: false)))
    }

    /// なくなった項目と、読めない値は捨てる。重なった項目は先に出たほうを残す。
    @Test func unknownAndDuplicateTokensAreDropped() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:a", "item:removed", "bogus", "hidden:a", "item:b", "item:c", "hidden:hiddenByDefault", "more", "more", "item:delete"])

        #expect(layout == TestMenuItem.defaultLayout.withoutSeparators)
    }

    /// 既定の並びで先頭の項目が足りなければ、並びの先頭に入る。
    @Test func missingFirstItemGoesToTop() {
        let layout = MenuLayout<TestMenuItem>(tokens: ["item:b", "item:c", "hidden:hiddenByDefault", "more", "item:delete"])

        #expect(layout.elements.first == .item(.a, isVisible: true))
    }

    /// 既定の並びは、設定を足す前のメニューと同じにし、あとから足した項目を加える。
    @Test func statusMenuDefaultMatchesMenuBeforeCustomization() {
        let groups = StatusMenuItem.defaultLayout.groups

        #expect(groups.main == [[.reply, .favourite, .reblog, .edit], [.copyLink, .share, .openInBrowser, .editHistory, .hideMedia], [.notifyingUser, .author, .booster]])
        #expect(groups.more == [[.delete]])
        #expect(UserMenuItem.defaultLayout.groups.main == [[.profile]])
    }

    /// 編集と削除を足す前に保存した並びでも、編集はブーストの後ろに、削除は「その他」に入る。
    @Test func savedStatusMenuGainsEditAndDelete() {
        let saved = MenuLayout<StatusMenuItem>(tokens: ["item:reblog", "item:reply", "item:favourite", "separator", "item:copyLink", "more", "hidden:share"])

        #expect(saved.groups.main.first == [.reblog, .edit, .reply, .favourite])
        #expect(saved.groups.more.first?.first == .delete)
    }

    @Test func appSettingsPersistsMenuLayouts() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).statusMenuLayout == StatusMenuItem.defaultLayout)

        let changed = MenuLayout<StatusMenuItem>(elements: [.item(.share, isVisible: true), .more, .item(.reply, isVisible: false)])
        AppSettings(defaults: defaults).statusMenuLayout = changed

        let restored = AppSettings(defaults: defaults).statusMenuLayout
        #expect(restored == changed)
        #expect(restored.groups.main.first?.first == .share)
    }
}

private extension MenuLayout where Item == TestMenuItem {
    /// 既定の並びから区切り線を除いたもの。
    var withoutSeparators: MenuLayout<TestMenuItem> {
        MenuLayout(elements: elements.filter { $0 != .separator })
    }
}
