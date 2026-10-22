import Foundation
import Testing
@testable import SciaCore

struct TabPlacementTests {
    /// 既定は、切り替えタブを使わず、今までどおり4つを直接並べる。
    @Test func defaultPlacesEveryTimelineDirectly() {
        let placement = TabPlacement(layout: TabItem.defaultLayout)
        #expect(placement.tabs == [.home, .local, .federated, .notifications])
        #expect(placement.switchable.isEmpty)
    }

    /// ブックマークとお気に入りは既定で無効にし、有効にすると切り替えタブに入る。保存済みの並びにも同じ位置で差し込む。
    @Test func savedListsStartDisabledBelowBoundary() {
        let saved = MenuLayout<TabItem>(tokens: ["item:home", "item:notifications", "more", "item:local", "item:federated"])
        #expect(saved.tokens == ["item:home", "item:notifications", "more", "hidden:bookmarks", "hidden:favourites", "item:local", "item:federated"])
        #expect(TabPlacement(layout: saved).location(of: .bookmarks) == .disabled)

        let enabled = MenuLayout<TabItem>(tokens: ["item:home", "more", "item:bookmarks"])
        #expect(TabPlacement(layout: enabled).location(of: .bookmarks) == .switchTab)
    }

    @Test func itemsBelowBoundaryGoToSwitchTabInOrder() {
        let layout = MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .item(.notifications, isVisible: true),
            .more,
            .item(.federated, isVisible: true),
            .item(.local, isVisible: true),
        ])
        let placement = TabPlacement(layout: layout)
        #expect(placement.tabs == [.home, .notifications])
        #expect(placement.switchable == [.federated, .local])
        #expect(placement.location(of: .notifications) == .tab)
        #expect(placement.location(of: .local) == .switchTab)
    }

    @Test func disabledItemsAreNowhere() {
        let layout = MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .item(.notifications, isVisible: false),
            .more,
            .item(.local, isVisible: true),
            .item(.federated, isVisible: false),
        ])
        let placement = TabPlacement(layout: layout)
        #expect(placement.tabs == [.home])
        #expect(placement.switchable == [.local])
        #expect(placement.location(of: .notifications) == .disabled)
        #expect(placement.location(of: .federated) == .disabled)
    }

    /// 設定画面では最後の1つを無効にできないが、保存した値が壊れて全部無効になっていても、タブバーを空にしない。
    @Test func allDisabledStillShowsHome() {
        let layout = MenuLayout<TabItem>(elements: TabItem.allCases.map { .item($0, isVisible: false) } + [.more])
        let placement = TabPlacement(layout: layout)
        #expect(placement.tabs == [.home])
        #expect(placement.switchable.isEmpty)
    }

    @Test func switchSelectionKeepsPreviousWhileItStaysInSwitchTab() {
        let placement = TabPlacement(layout: MenuLayout<TabItem>(elements: [
            .item(.home, isVisible: true),
            .more,
            .item(.local, isVisible: true),
            .item(.federated, isVisible: true),
            .item(.notifications, isVisible: true),
        ]))
        #expect(placement.switchSelection(previous: nil) == .local)
        #expect(placement.switchSelection(previous: .federated) == .federated)
        // タブへ移したか無効にした項目は、切り替えタブの先頭に戻す。
        #expect(placement.switchSelection(previous: .home) == .local)
        #expect(TabPlacement(layout: TabItem.defaultLayout).switchSelection(previous: .local) == nil)
    }
}

@MainActor
struct TabLayoutSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "TabLayoutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// リストはアカウントごとに違うため、並びもアカウントごとに持つ。
    @Test func tabLayoutIsPerAccountAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let changed = MenuLayout<TabItem>(elements: [.item(.home, isVisible: true), .more, .item(.local, isVisible: true)])
        settings.setTabLayout(changed, for: "@alice@example.social")

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.tabLayout(for: "@alice@example.social") == changed)
        #expect(relaunched.tabLayout(for: "@bob@example.social") == TabItem.defaultLayout)
    }

    /// 切り替えタブで最後に開いた項目は、起動し直しても覚えておく。アカウントごとに持つ。
    @Test func switchTabItemIsPerAccountAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.setSwitchTabItem(.notifications, for: "@alice@example.social")

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.switchTabItem(for: "@alice@example.social") == .notifications)
        #expect(relaunched.switchTabItem(for: "@bob@example.social") == nil)
    }

    /// リストはIDと名前を並びに残し、同じ項目かどうかはIDだけで見る。名前に`:`が入っていても読める。
    @Test func listItemKeepsTitleButIsIdentifiedByID() {
        let item = TabItem.list(id: "12249", title: "仕事: 開発")
        #expect(item.rawValue == "list:12249:仕事: 開発")
        #expect(TabItem(rawValue: item.rawValue) == item)
        if case .list(_, let title) = TabItem(rawValue: item.rawValue) {
            #expect(title == "仕事: 開発")
        } else {
            Issue.record("リストとして読めませんでした")
        }
        #expect(item == .list(id: "12249", title: "別の名前"))
        #expect(item != .list(id: "13585", title: "仕事: 開発"))
        #expect(TabItem(rawValue: "list:") == nil)
        #expect(TabItem(.list(id: "12249")) == item)
    }

    /// 保存した並びのリストは、名前とともに読み戻せる。
    @Test func listItemSurvivesSavedTokens() {
        let layout = MenuLayout<TabItem>(tokens: ["item:home", "more", "item:list:5:友だち"])
        #expect(layout.tokens.contains("item:list:5:友だち"))
        #expect(TabPlacement(layout: layout).switchable == [.list(id: "5", title: "友だち")])
    }

    /// まだないリストは無効にして末尾に足し、もうないリストは外し、名前が変わったリストは書き換える。表示と並びはそのまま残す。
    @Test func syncingListsAddsRemovesAndRenames() {
        let layout = MenuLayout<TabItem>(tokens: ["item:home", "item:list:1:旧名", "more", "item:local", "hidden:list:2:消えるリスト"])

        let synced = layout.syncingLists([MastodonList(id: "1", title: "新名"), MastodonList(id: "3", title: "新しいリスト")])

        #expect(synced.tokens.filter { $0.contains("list:") } == ["item:list:1:新名", "hidden:list:3:新しいリスト"])
        #expect(synced.tokens.firstIndex(of: "item:list:1:新名") == 1)
        #expect(synced.tokens.last == "hidden:list:3:新しいリスト")
        #expect(synced.listIDs == ["1", "3"])
    }

    /// 切り替えタブで前に開いていた項目は、保存しておいた古い名前ではなく、並びの中の今の名前で返す。
    @Test func switchSelectionUsesCurrentListTitle() {
        let layout = MenuLayout<TabItem>(tokens: ["item:home", "more", "item:list:1:新名"])
        let restored = TabPlacement(layout: layout).switchSelection(previous: .list(id: "1", title: "旧名"))
        #expect(restored?.rawValue == "list:1:新名")
    }

    /// 足りないリストだけを無効で足し、並びにあるリストは外しも書き換えもしない。
    @Test func addingMissingListsOnlyAppends() {
        let layout = MenuLayout<TabItem>(tokens: ["item:home", "more", "item:list:1:旧名", "item:list:9:ほかのウインドウで読んだリスト"])

        let added = layout.addingMissingLists([MastodonList(id: "1", title: "新名"), MastodonList(id: "2", title: "足りないリスト")])

        #expect(added.tokens.filter { $0.contains("list:") } == ["item:list:1:旧名", "item:list:9:ほかのウインドウで読んだリスト", "hidden:list:2:足りないリスト"])
        #expect(added.addingMissingLists([MastodonList(id: "2", title: "足りないリスト")]).tokens == added.tokens)
    }

    /// 名前だけが変わった並びは、項目どうしでは同じでも、保存の形では違う。設定画面は保存の形で並びの変化を見分ける。
    @Test func renamedListChangesTokensButNotItems() {
        let before = MenuLayout<TabItem>(tokens: ["item:home", "more", "item:list:1:旧名"])
        let after = before.syncingLists([MastodonList(id: "1", title: "新名")])
        #expect(after.elements == before.elements)
        #expect(after.tokens != before.tokens)
    }
}
