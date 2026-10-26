import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct TabArrangementTests {
    /// 確かめに使うリスト。
    private static let friends = TabItem.list(id: "1", title: "友だち")

    /// 項目ごとのナビゲーション。作るように頼まれた項目を記録する。
    /// 項目ごとのナビゲーション。リストは、アプリと同じく頼まれるたびに新しく作る。作るように頼まれた項目を記録する。
    @MainActor
    private final class Navigations {
        /// 項目ごとの、いちばん新しく作ったナビゲーション。
        private(set) var all: [TabItem: UINavigationController]
        private(set) var made: [TabItem] = []

        init() {
            var all: [TabItem: UINavigationController] = [:]
            for item in TabItem.allCases {
                all[item] = Self.navigation(for: item)
            }
            self.all = all
        }

        private static func navigation(for item: TabItem) -> UINavigationController {
            let root = UIViewController()
            root.title = item.title
            return UINavigationController(rootViewController: root)
        }

        func make(_ item: TabItem) -> UINavigationController? {
            made.append(item)
            if item == TabArrangementTests.friends {
                all[item] = Self.navigation(for: item)
            }
            return all[item]
        }
    }

    @MainActor
    private struct Harness {
        let arrangement: TabArrangement
        let made: Navigations
        let window: UIWindow

        var navigations: [TabItem: UINavigationController] { made.all }

        init(_ layout: MenuLayout<TabItem>, restoring: TabItem? = nil) throws {
            let made = Navigations()
            self.made = made
            arrangement = TabArrangement(navigation: made.make, layout: layout, restoring: restoring)
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "テストのホストアプリにウィンドウシーンがありません"
            )
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = arrangement.tabBarController
            window.makeKeyAndVisible()
        }

        func apply(_ layout: MenuLayout<TabItem>) {
            arrangement.apply(layout)
            window.layoutIfNeeded()
        }

        var tabIdentifiers: [String] { arrangement.tabBarController.tabs.map(\.identifier) }
        var switchTitle: String? { arrangement.tabBarController.tabs.first { $0.identifier == TabArrangement.switchIdentifier }?.title }
    }

    /// 並びに書かなかった項目は、`MenuLayout`が既定の位置に表示する状態で差し込む。
    private static func layout(tabs: [TabItem], switchable: [TabItem], disabled: Set<TabItem> = []) -> MenuLayout<TabItem> {
        MenuLayout(elements: tabs.map { .item($0, isVisible: !disabled.contains($0)) } + [.more] + switchable.map { .item($0, isVisible: !disabled.contains($0)) })
    }

    @Test func switchTabShowsFirstItemAndFollowsSelection() throws {
        let harness = try Harness(Self.layout(tabs: [.home], switchable: [.local, .federated, .notifications]))
        #expect(harness.tabIdentifiers == ["home", TabArrangement.switchIdentifier])
        #expect(harness.switchTitle == "ローカル")

        harness.arrangement.show(.notifications)
        #expect(harness.arrangement.isShowing(.notifications))
        #expect(harness.arrangement.selectedNavigation === harness.navigations[.notifications])
        #expect(harness.switchTitle == "通知")
    }

    /// iOS 27以降では、切り替えタブがあるときだけ、それを目立たせるタブにする。
    @Test func switchTabIsProminentOnlyWhilePlaced() throws {
        guard #available(iOS 27.0, *) else { return }
        let harness = try Harness(Self.layout(tabs: [.home], switchable: [.local, .federated]))
        #expect(harness.arrangement.tabBarController.prominentTabIdentifier == TabArrangement.switchIdentifier)

        harness.apply(Self.layout(tabs: [.home, .local, .federated], switchable: []))
        #expect(!harness.tabIdentifiers.contains(TabArrangement.switchIdentifier))
        #expect(harness.arrangement.tabBarController.prominentTabIdentifier == nil)
    }

    /// 起動し直したときは、前に切り替えタブで開いていた項目から開く。もう切り替えタブになければ先頭から開く。
    @Test func restoresSwitchSelection() throws {
        let restored = try Harness(Self.layout(tabs: [.home], switchable: [.local, .federated, .notifications]), restoring: .notifications)
        #expect(restored.switchTitle == "通知")
        #expect(restored.arrangement.switchSelection == .notifications)

        let moved = try Harness(Self.layout(tabs: [.home, .notifications], switchable: [.local, .federated]), restoring: .notifications)
        #expect(moved.switchTitle == "ローカル")
    }

    /// 切り替えタブで開いていた項目を無効にしたら、残った先頭に切り替える。切り替えタブを作り直しても落ちない。
    @Test func disablingShownItemInSwitchTabMovesToNextItem() throws {
        let harness = try Harness(Self.layout(tabs: [.home], switchable: [.local, .notifications]))
        harness.arrangement.show(.notifications)

        harness.apply(Self.layout(tabs: [.home], switchable: [.local, .notifications], disabled: [.notifications]))

        #expect(harness.switchTitle == "ローカル")
        #expect(harness.arrangement.switchSelection == .local)
    }

    /// 項目をタブと切り替えタブの間で行き来させても、同じナビゲーションのまま開ける。
    @Test func movingItemsBetweenTabAndSwitchTabKeepsTheirNavigation() throws {
        let harness = try Harness(Self.layout(tabs: [.home], switchable: [.local, .federated]))
        harness.arrangement.show(.local)

        harness.apply(Self.layout(tabs: [.home, .local], switchable: [.federated]))
        #expect(harness.tabIdentifiers == ["home", "local", TabArrangement.switchIdentifier])
        #expect(harness.arrangement.isShowing(.local))
        #expect(harness.arrangement.selectedNavigation === harness.navigations[.local])

        harness.apply(Self.layout(tabs: [.home], switchable: [.local, .federated]))
        #expect(harness.arrangement.isShowing(.local))
        #expect(harness.arrangement.selectedNavigation === harness.navigations[.local])

        harness.apply(Self.layout(tabs: [.home, .local, .federated], switchable: [.notifications], disabled: [.notifications]))
        #expect(harness.tabIdentifiers == ["home", "local", "federated"])
        #expect(harness.arrangement.selectedNavigation === harness.navigations[.local])
    }

    /// 横幅の狭いタブバーに入りきらない項目は、UIKitの「その他」に任せず切り替えタブに入れ、開いたあともほかのタブへ移れる。
    @Test func overflowingTabsGoToSwitchTabInsteadOfMore() throws {
        let harness = try Harness(Self.layout(tabs: [.home, .notifications, .local, .federated, .bookmarks, .favourites], switchable: []))
        #expect(harness.tabIdentifiers == ["home", "notifications", "local", "federated", TabArrangement.switchIdentifier])
        #expect(harness.switchTitle == "ブックマーク")

        harness.arrangement.show(.favourites)
        #expect(harness.arrangement.isShowing(.favourites))
        #expect(harness.arrangement.selectedNavigation === harness.navigations[.favourites])

        harness.arrangement.show(.home)
        #expect(harness.arrangement.isShowing(.home))
        #expect(harness.arrangement.tabBarController.selectedTab?.identifier == "home")
    }

    /// 横幅の広いiPadのタブバーになったら、数を限らず直接並べ直し、見ていた項目を開いたままにする。狭くなったら切り替えタブに戻す。
    @Test func regularWidthPadPlacesEveryTabDirectly() throws {
        let harness = try Harness(Self.layout(tabs: [.home, .notifications, .local, .federated, .bookmarks, .favourites], switchable: []))
        harness.arrangement.show(.favourites)

        harness.arrangement.tabBarController.traitOverrides.userInterfaceIdiom = .pad
        harness.arrangement.tabBarController.traitOverrides.horizontalSizeClass = .regular
        harness.window.layoutIfNeeded()
        #expect(harness.tabIdentifiers == ["home", "notifications", "local", "federated", "bookmarks", "favourites"])
        #expect(harness.arrangement.isShowing(.favourites))
        #expect(harness.arrangement.selectedNavigation === harness.navigations[.favourites])

        harness.arrangement.tabBarController.traitOverrides.horizontalSizeClass = .compact
        harness.window.layoutIfNeeded()
        #expect(harness.tabIdentifiers == ["home", "notifications", "local", "federated", TabArrangement.switchIdentifier])
        #expect(harness.arrangement.isShowing(.favourites))
    }

    /// 通知の未読の数は、通知を置いた場所のタブに出す。
    @Test func notificationsBadgeFollowsNotifications() throws {
        let harness = try Harness(Self.layout(tabs: [.home, .notifications], switchable: [.local]))
        harness.arrangement.setNotificationsBadge("3")
        #expect(harness.arrangement.tabBarController.tabs.first { $0.identifier == "notifications" }?.badgeValue == "3")

        harness.apply(Self.layout(tabs: [.home], switchable: [.local, .notifications]))
        let switchTab = harness.arrangement.tabBarController.tabs.first { $0.identifier == TabArrangement.switchIdentifier }
        #expect(switchTab?.badgeValue == "3")
    }

    /// 切り替えタブの中で開く項目を変えても、通知の未読の数は切り替えタブに出したままにする。
    @Test func switchTabKeepsNotificationsBadgeWhenSwitching() throws {
        let harness = try Harness(Self.layout(tabs: [.home], switchable: [.local, .federated, .notifications]))
        harness.arrangement.setNotificationsBadge("2")

        harness.arrangement.show(.federated)

        let switchTab = harness.arrangement.tabBarController.tabs.first { $0.identifier == TabArrangement.switchIdentifier }
        #expect(switchTab?.badgeValue == "2")
    }

    /// リストのように数の決まらない項目は、並びに出たときにナビゲーションを作り、タブと切り替えタブを行き来しても作り直さない。
    /// 無効にしている項目は作らない。
    @Test func listNavigationIsMadeOnceWhenPlaced() throws {
        let harness = try Harness(Self.layout(tabs: [.home], switchable: [.local, Self.friends], disabled: [Self.friends]))
        #expect(!harness.made.made.contains(Self.friends))

        harness.apply(Self.layout(tabs: [.home, Self.friends], switchable: [.local]))
        #expect(harness.tabIdentifiers == ["home", "list:1:友だち", TabArrangement.switchIdentifier])

        harness.apply(Self.layout(tabs: [.home], switchable: [Self.friends, .local]))
        harness.arrangement.show(Self.friends)
        #expect(harness.arrangement.isShowing(Self.friends))
        #expect(harness.arrangement.selectedNavigation === harness.navigations[Self.friends])
        #expect(harness.switchTitle == "友だち")
        #expect(harness.made.made.filter { $0 == Self.friends }.count == 1)
    }

    /// サーバーから消えた項目は、並びから外れたら作ったナビゲーションを捨てる。同じ項目がまた並びに出たら作り直し、止めた一覧を使い回さない。
    @Test func forgottenItemIsMadeAgainWhenPlacedAgain() throws {
        let harness = try Harness(Self.layout(tabs: [.home, Self.friends], switchable: [.local]))
        #expect(harness.made.made.filter { $0 == Self.friends }.count == 1)

        harness.arrangement.forget([Self.friends])
        harness.apply(Self.layout(tabs: [.home], switchable: [.local], disabled: []).withoutItem(Self.friends))
        harness.apply(Self.layout(tabs: [.home, Self.friends], switchable: [.local]))

        #expect(harness.made.made.filter { $0 == Self.friends }.count == 2)
    }

    /// まだ並びにある項目は、忘れるよう頼まれても、並びから外れるまで捨てない。
    @Test func forgottenItemStaysWhilePlaced() throws {
        let harness = try Harness(Self.layout(tabs: [.home, Self.friends], switchable: [.local]))

        harness.arrangement.forget([Self.friends])
        harness.arrangement.show(Self.friends)

        #expect(harness.arrangement.isShowing(Self.friends))
        #expect(harness.made.made.filter { $0 == Self.friends }.count == 1)
    }
}

private extension MenuLayout where Item == TabItem {
    /// 並びから項目を外す。リストやハッシュタグは既定の並びにないため、外すと並びに戻らない。
    func withoutItem(_ item: TabItem) -> MenuLayout<TabItem> {
        MenuLayout(elements: elements.filter { element in
            if case .item(let candidate, _) = element { candidate != item } else { true }
        })
    }
}
