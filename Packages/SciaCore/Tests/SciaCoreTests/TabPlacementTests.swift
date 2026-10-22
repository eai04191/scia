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
}
