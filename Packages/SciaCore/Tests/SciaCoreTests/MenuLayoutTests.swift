import Foundation
import Testing
import SciaTesting
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

@Suite(.scratch)
@MainActor
struct MenuLayoutTests {
    private func makeDefaults() throws -> UserDefaults {
        let defaults = TestScratch.defaults("MenuLayoutTests")
        return defaults
    }

    @Test func groupsSplitBySeparatorAndMore() {
        let groups = TestMenuItem.defaultLayout.groups

        #expect(groups.main.map(\.items) == [[.a, .b], [.c]])
        #expect(groups.more.map(\.items) == [[.delete]])
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

        #expect(layout.groups.main.map(\.items) == [[.b, .c]])
        #expect(layout.groups.more.map(\.items) == [])
    }

    /// 横並びの区切り線は、並びの先頭や「その他」の境目のすぐ下でも、その下のまとまりを横に並べる。次の区切り線で横並びは終わる。
    @Test func rowSeparatorMakesFollowingGroupARow() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .rowSeparator,
            .item(.a, isVisible: true),
            .item(.b, isVisible: true),
            .separator,
            .item(.c, isVisible: true),
            .item(.hiddenByDefault, isVisible: false),
            .more,
            .rowSeparator,
            .item(.delete, isVisible: true),
        ])

        #expect(layout.groups.main == [.init([.a, .b], isRow: true), .init([.c])])
        #expect(layout.groups.more == [.init([.delete], isRow: true)])
    }

    /// 中身がすべて非表示の横並びのまとまりは出さず、横並びを次のまとまりに持ち越さない。
    @Test func emptyRowGroupDoesNotCarryOver() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .item(.a, isVisible: true),
            .rowSeparator,
            .item(.b, isVisible: false),
            .separator,
            .item(.c, isVisible: true),
            .item(.hiddenByDefault, isVisible: false),
            .more,
            .item(.delete, isVisible: true),
        ])

        #expect(layout.groups.main == [.init([.a]), .init([.c])])
    }

    /// ほかの対象のメニューの中のサブメニューでは、タップと長押しに割り当てた項目を、隠していても並びの位置に出す。メニューを開くは項目ではないので何も足さない。
    @Test func submenuGroupsRevealAssignedItemsInPlace() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .item(.a, isVisible: false),
            .item(.b, isVisible: true),
            .separator,
            .item(.c, isVisible: true),
            .item(.hiddenByDefault, isVisible: false),
            .more,
            .item(.delete, isVisible: true),
        ])

        let groups = layout.submenuGroups(actions: ObjectActions(tap: .item(.hiddenByDefault), longPress: .item(.a)))

        #expect(groups.main.map(\.items) == [[.a, .b], [.c, .hiddenByDefault]])
        #expect(groups.more.map(\.items) == [[.delete]])
        #expect(layout.submenuGroups(actions: ObjectActions(tap: .menu, longPress: .menu)) == layout.groups)
    }

    /// 表示にしている項目を割り当てていても、二重に出さない。
    @Test func submenuGroupsDoNotDuplicateVisibleItems() {
        let groups = TestMenuItem.defaultLayout.submenuGroups(actions: ObjectActions(tap: .item(.b), longPress: .item(.b)))

        #expect(groups == TestMenuItem.defaultLayout.groups)
    }

    @Test func tokensRoundTripIncludingHiddenItemsAndSeparators() {
        let layout = MenuLayout<TestMenuItem>(elements: [
            .rowSeparator,
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

        #expect(layout.groups.main.map(\.items) == [[.a]])
        #expect(layout.groups.more.map(\.items) == [[.delete, .b, .c]])
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

    /// 関係で中身が変わる項目を1つでも出していれば、メニューを開いたときに関係を読む。「その他」の中にあっても読む。
    /// 通報だけなら、自分かどうかはIDで決まるので読まない。
    @Test func userMenuNeedsRelationshipOnlyWithRelationDependentItems() {
        func layout(_ tokens: [String]) -> MenuLayout<UserMenuItem>.Groups {
            MenuLayout<UserMenuItem>(elements: MenuLayout<UserMenuItem>(tokens: tokens).elements.map { element in
                guard case .item(let item, _) = element else { return element }
                return .item(item, isVisible: tokens.contains("item:\(item.rawValue)"))
            }).groups
        }

        #expect(MenuFixture.user.groups.needsRelationship)
        #expect(layout(["item:profile", "more", "item:mute"]).needsRelationship)
        #expect(!layout(["item:profile", "item:copyLink", "more", "item:report"]).needsRelationship)
    }

    @Test func appSettingsPersistsMenuLayouts() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).statusMenuLayout == StatusMenuItem.defaultLayout)

        let changed = MenuLayout<StatusMenuItem>(elements: [.item(.share, isVisible: true), .more, .item(.reply, isVisible: false)])
        AppSettings(defaults: defaults).statusMenuLayout = changed

        let restored = AppSettings(defaults: defaults).statusMenuLayout
        #expect(restored == changed)
    }

    @Test func appSettingsPersistsMediaMenuLayout() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).mediaMenuLayout == MediaMenuItem.defaultLayout)

        let media = MenuLayout<MediaMenuItem>(elements: [.item(.saveToPhotos, isVisible: true), .more, .item(.open, isVisible: false)])
        AppSettings(defaults: defaults).mediaMenuLayout = media

        #expect(AppSettings(defaults: defaults).mediaMenuLayout == media)
    }

    @Test func appSettingsPersistsLinkAndHashtagMenuLayouts() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).linkMenuLayout == LinkMenuItem.defaultLayout)
        #expect(AppSettings(defaults: defaults).hashtagMenuLayout == HashtagMenuItem.defaultLayout)

        let link = MenuLayout<LinkMenuItem>(elements: [.item(.share, isVisible: true), .more, .item(.openInBrowser, isVisible: false)])
        let hashtag = MenuLayout<HashtagMenuItem>(elements: [.item(.copyLink, isVisible: true), .separator, .item(.openInBrowser, isVisible: false), .more])
        let settings = AppSettings(defaults: defaults)
        settings.linkMenuLayout = link
        settings.hashtagMenuLayout = hashtag

        let restored = AppSettings(defaults: defaults)
        #expect(restored.linkMenuLayout == link)
        #expect(restored.hashtagMenuLayout == hashtag)
    }

    @Test func appSettingsPersistsProfileTextMenuLayout() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).profileTextMenuLayout == ProfileTextMenuItem.defaultLayout)

        let layout = MenuLayout<ProfileTextMenuItem>(elements: [.item(.customEmojis, isVisible: true), .separator, .item(.copyText, isVisible: false), .more])
        AppSettings(defaults: defaults).profileTextMenuLayout = layout

        #expect(AppSettings(defaults: defaults).profileTextMenuLayout == layout)
    }

    @Test func appSettingsPersistsExternalPostMenuLayout() throws {
        let defaults = try makeDefaults()
        #expect(AppSettings(defaults: defaults).externalPostMenuLayout == ExternalPostMenuItem.defaultLayout)

        let layout = MenuLayout<ExternalPostMenuItem>(elements: [.item(.systemTranslate, isVisible: true), .separator, .item(.share, isVisible: false), .more])
        AppSettings(defaults: defaults).externalPostMenuLayout = layout

        #expect(AppSettings(defaults: defaults).externalPostMenuLayout == layout)
    }
}

private extension MenuLayout where Item == TestMenuItem {
    /// 既定の並びから区切り線を除いたもの。
    var withoutSeparators: MenuLayout<TestMenuItem> {
        MenuLayout(elements: elements.filter { $0 != .separator })
    }
}
