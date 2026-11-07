import Foundation
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct PostActionBarTests {
    /// 既定は返信、ブースト、お気に入り、ブックマーク、メニューの順に並べる（docs/post-action-bar.mdの「ボタン」）。
    @Test func defaultLayoutShowsCommonButtons() {
        #expect(PostActionBarItem.defaultLayout.actionBarItems == [.status(.reply), .status(.reblog), .status(.favourite), .status(.bookmark), .menu])
    }

    /// 並べられないもののほかは、投稿のメニューの項目をすべて並びに持ち、選べるようにする。
    @Test func layoutHoldsEveryPlaceableStatusItem() {
        let items = Set(PostActionBarItem.defaultLayout.elements.compactMap { element -> PostActionBarItem? in
            guard case .item(let item, _) = element else { return nil }
            return item
        })
        #expect(items == Set(PostActionBarItem.allCases))
        #expect(!items.contains(.status(.customize)))
    }

    @Test func persistsLayout() {
        let defaults = TestScratch.defaults("PostActionBarTests")
        let settings = AppSettings(defaults: defaults)
        let elements = PostActionBarItem.defaultLayout.elements.map { element -> MenuLayout<PostActionBarItem>.Element in
            guard case .item(let item, _) = element else { return element }
            return .item(item, isVisible: item == .menu || item == .status(.share))
        }
        settings.postActionBarLayout = MenuLayout(elements: elements)
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.postActionBarLayout.actionBarItems == [.menu, .status(.share)])
    }

    @Test func rawValuesRoundTrip() {
        for item in PostActionBarItem.allCases {
            #expect(PostActionBarItem(rawValue: item.rawValue) == item)
        }
        #expect(PostActionBarItem(rawValue: "customize") == nil)
    }

    @Test func readsActionBarToken() {
        let defaults = TestScratch.defaults("PostActionBarTests")
        defaults.set(["actionBar", "menu"], forKey: "settings.objectActions.status")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.statusActions == ObjectActions(tap: .actionBar, longPress: .menu))
        #expect(ObjectAction<StatusMenuItem>.actionBar.token == "actionBar")
    }

    @Test func buttonsShowStateAndCounts() {
        let status = Status.fixture(favourited: true, reblogged: false, bookmarked: true, favouritesCount: 12, reblogsCount: 0, repliesCount: 3)
        let buttons = PostActionBarButton.buttons(for: status, items: PostActionBarItem.defaultLayout.actionBarItems, showsCounts: true) { _ in true }
        let byItem = Dictionary(uniqueKeysWithValues: buttons.map { ($0.item, $0) })
        #expect(byItem[.status(.reply)]?.count == 3)
        // 0は添えない。
        #expect(byItem[.status(.reblog)]?.count == nil)
        #expect(byItem[.status(.reblog)]?.isOn == false)
        #expect(byItem[.status(.reblog)]?.tint == PostActionBarButton.Tint.none)
        #expect(byItem[.status(.favourite)]?.count == 12)
        #expect(byItem[.status(.favourite)]?.isOn == true)
        #expect(byItem[.status(.favourite)]?.tint == .favourite)
        #expect(byItem[.status(.favourite)]?.symbolName == "star.fill")
        #expect(byItem[.status(.bookmark)]?.symbolName == "bookmark.fill")
        #expect(byItem[.status(.bookmark)]?.tint == .bookmark)
        #expect(byItem[.menu]?.count == nil)
    }

    @Test func hidesCountsWhenTurnedOff() {
        let status = Status.fixture(favouritesCount: 12, reblogsCount: 4, repliesCount: 3)
        let buttons = PostActionBarButton.buttons(for: status, items: PostActionBarItem.defaultLayout.actionBarItems, showsCounts: false) { _ in true }
        #expect(buttons.allSatisfy { $0.count == nil })
    }

    /// 件数は1万より小さければ桁区切りで出し、1万からは「1.2万」のように万の単位で縮める。幅に入りきらずに切れないため。
    @Test(arguments: [(0, "0"), (9_999, "9,999"), (10_000, "1万"), (12_345, "1.2万"), (234_567, "23万"), (1_234_567, "123万"), (123_456_789, "1.2億"), (1_234_567_890_123, "1.2兆")])
    func shortensLargeCounts(count: Int, text: String) {
        #expect(PostActionBarButton.countText(count) == text)
    }

    /// 長押しのメニューは、ブーストとお気に入りのボタンにだけある。
    /// メニューから除く項目は、設定ごとに、並べたボタンの項目と、並べたボタンの長押しの項目を足し合わせる。
    @Test func itemsRemovedFromMenuFollowSettings() {
        let layout = PostActionBarItem.defaultLayout
        let barItems: Set<StatusMenuItem> = [.reply, .reblog, .favourite, .bookmark]
        let longPressItems: Set<StatusMenuItem> = [.reblogWithVisibility, .quote, .rebloggedBy, .favouritedBy]
        #expect(layout.itemsRemovedFromMenu(barItems: true, longPressItems: false) == barItems)
        #expect(layout.itemsRemovedFromMenu(barItems: false, longPressItems: true) == longPressItems)
        #expect(layout.itemsRemovedFromMenu(barItems: true, longPressItems: true) == barItems.union(longPressItems))
        #expect(layout.itemsRemovedFromMenu(barItems: false, longPressItems: false).isEmpty)
    }

    /// 長押しの項目は、そのボタンを並べているときだけ除く。
    @Test func longPressItemsAreRemovedOnlyForShownButtons() {
        let elements = PostActionBarItem.defaultLayout.elements.map { element -> MenuLayout<PostActionBarItem>.Element in
            guard case .item(let item, _) = element else { return element }
            return .item(item, isVisible: item == .status(.favourite))
        }
        let layout = MenuLayout(defaultElements: elements)
        #expect(layout.itemsRemovedFromMenu(barItems: false, longPressItems: true) == [.favouritedBy])
    }

    /// 既定ではアクションバーの項目を除き、長押しの項目は除かない。変えた値は保存する。
    @Test func persistsMenuRemovalSettings() {
        let defaults = TestScratch.defaults("PostActionBarMenuRemoval")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.removesActionBarItemsFromMenu)
        #expect(!settings.removesActionBarLongPressItemsFromMenu)
        settings.removesActionBarItemsFromMenu = false
        settings.removesActionBarLongPressItemsFromMenu = true
        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.removesActionBarItemsFromMenu)
        #expect(reloaded.removesActionBarLongPressItemsFromMenu)
    }

    /// 読み直しを外したハッシュタグの操作でメニューを組んでも、読み直さない。ミュートの項目は同じく出す。
    @Test func hashtagActionsWithoutRefreshDoNotRefresh() {
        var refreshes = 0
        let actions = HashtagMenuActions(
            mute: HashtagMuteActions(known: { _ in false }, refresh: { refreshes += 1 }, load: { _ in false }, mute: { _, _ in }, unmute: { _ in }),
            follow: HashtagToggleActions(known: { _ in false }, refresh: { refreshes += 1 }, load: { _ in false }, turnOn: { _ in }, turnOff: { _ in }),
            feature: HashtagToggleActions(known: { _ in false }, refresh: { refreshes += 1 }, load: { _ in false }, turnOn: { _ in }, turnOff: { _ in })
        )
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil)
        let tree = HashtagMenuTree(name: "cat", url: nil, account: account, linkBrowser: .inApp, actions: actions.withoutRefresh)
        let titles = tree.submenu(groups: HashtagMenuItem.defaultLayout.groups)?.flattenedChildren.map(\.title) ?? []
        #expect(refreshes == 0)
        #expect(!titles.isEmpty)
        _ = HashtagMenuTree(name: "cat", url: nil, account: account, linkBrowser: .inApp, actions: actions).submenu(groups: HashtagMenuItem.defaultLayout.groups)
        #expect(refreshes > 0)
    }

    @Test func longPressItems() {
        #expect(PostActionBarItem.status(.reblog).longPressItems == [.reblogWithVisibility, .quote, .rebloggedBy])
        #expect(PostActionBarItem.status(.favourite).longPressItems == [.favouritedBy])
        #expect(PostActionBarItem.status(.reply).longPressItems.isEmpty)
        #expect(PostActionBarItem.menu.longPressItems.isEmpty)
    }

    @Test func marksUnavailableItems() {
        let status = Status.fixture()
        let buttons = PostActionBarButton.buttons(for: status, items: [.status(.reblog), .status(.edit), .menu], showsCounts: true) { $0 == .reblog }
        #expect(buttons.map(\.isAvailable) == [true, false, true])
    }
}

private extension Status {
    static func fixture(favourited: Bool = false, reblogged: Bool = false, bookmarked: Bool = false, favouritesCount: Int = 0, reblogsCount: Int = 0, repliesCount: Int = 0) -> Status {
        let account = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: nil, url: URL(string: "https://example.social/@alice"))
        return Status(
            id: "100",
            createdAt: Date(timeIntervalSince1970: 100),
            account: account,
            content: "<p>こんにちは</p>",
            spoilerText: "",
            url: nil,
            favourited: favourited,
            reblogged: reblogged,
            bookmarked: bookmarked,
            favouritesCount: favouritesCount,
            reblogsCount: reblogsCount,
            repliesCount: repliesCount
        )
    }
}
