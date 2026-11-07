import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.scratch)
struct TabArrangementTests {
    /// 確かめに使うリスト。
    private static let friends = TabItem.list(id: "1", title: "友だち")
    /// 確かめに使うプロフィール。
    private static let bob = TabItem.profile(accountID: "2", acct: "bob")
    private static let carol = TabItem.profile(accountID: "3", acct: "carol")

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
            if item == TabArrangementTests.friends || item.isProfile {
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

        init(_ layout: MenuLayout<TabItem>, restoring: TabItem? = nil, settings: AppSettings = .isolated()) throws {
            let made = Navigations()
            self.made = made
            arrangement = TabArrangement(navigation: made.make, layout: layout, restoring: restoring, settings: settings)
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

    /// 並びに書かなかった項目は、`MenuLayout`が既定の位置と表示で差し込む。
    /// 既定の並びを変えても確かめるタブの並びが変わらないよう、書かなかった項目は無効にして末尾に置く。
    private static func layout(tabs: [TabItem], switchable: [TabItem], disabled: Set<TabItem> = []) -> MenuLayout<TabItem> {
        let unlisted = TabItem.allCases.filter { !(tabs + switchable).contains($0) }.map { MenuLayout<TabItem>.Element.item($0, isVisible: false) }
        return MenuLayout(elements: tabs.map { .item($0, isVisible: !disabled.contains($0)) } + [.more] + switchable.map { .item($0, isVisible: !disabled.contains($0)) } + unlisted)
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

    /// iOS 27以降では、切り替えタブのボタン（タブバーの右端の丸）を長押ししたときだけ、中の項目から選ぶメニューを出す。ほかのタブの長押しには出さない。
    @Test func longPressOnSwitchTabOffersMenu() throws {
        guard #available(iOS 27.0, *) else { return }
        let harness = try Harness(Self.layout(tabs: [.home, .notifications], switchable: [.local, .federated]))
        harness.window.layoutIfNeeded()
        let tabBar = harness.arrangement.tabBarController.tabBar
        let menu = try #require(harness.arrangement.switchTabMenu)

        let groups = tabBar.subviews.filter { !$0.bounds.isEmpty }.sorted { $0.frame.minX < $1.frame.minX }
        let circle = try #require(groups.last)
        let tabs = try #require(groups.first)
        #expect(circle !== tabs)
        #expect(menu.switchTabButton(at: CGPoint(x: circle.frame.midX, y: circle.frame.midY)) === circle)
        #expect(menu.switchTabButton(at: CGPoint(x: tabs.frame.minX + 20, y: tabs.frame.midY)) == nil)
        #expect(menu.switchTabButton(at: CGPoint(x: tabs.frame.maxX - 20, y: tabs.frame.midY)) == nil)
    }

    /// 切り替えタブがないときは、どこを長押ししてもメニューを出さない。
    @Test func longPressOffersNoMenuWithoutSwitchTab() throws {
        guard #available(iOS 27.0, *) else { return }
        let harness = try Harness(Self.layout(tabs: [.home, .notifications], switchable: []))
        harness.window.layoutIfNeeded()
        let tabBar = harness.arrangement.tabBarController.tabBar
        let menu = try #require(harness.arrangement.switchTabMenu)

        let groups = tabBar.subviews.filter { !$0.bounds.isEmpty }
        #expect(!groups.isEmpty)
        for group in groups {
            #expect(menu.switchTabButton(at: CGPoint(x: group.frame.midX, y: group.frame.midY)) == nil)
            #expect(menu.switchTabButton(at: CGPoint(x: group.frame.maxX - 20, y: group.frame.midY)) == nil)
        }
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

    /// タブに並べたプロフィールの名前を変えると、同じナビゲーションのまま、新しい名前のタブに差し替える。
    /// UIKitは1つの画面を2つのタブに渡すとアサーションで落ちるため、作り直したタブにも同じ画面を渡さない。
    @Test func renamingPlacedProfileKeepsItsNavigation() throws {
        let harness = try Harness(Self.layout(tabs: [.home, Self.bob], switchable: [.local]))
        harness.arrangement.show(Self.bob)
        let navigation = try #require(harness.arrangement.selectedNavigation)

        harness.apply(Self.layout(tabs: [.home, Self.bob.renamed("ボブ")], switchable: [.local]))

        #expect(harness.arrangement.tabBarController.tabs.map(\.title) == ["ホーム", "ボブ", "ローカル"])
        #expect(harness.arrangement.isShowing(Self.bob))
        #expect(harness.arrangement.selectedNavigation === navigation)

        // 名前を変えたあとも、切り替えタブとの行き来で同じナビゲーションを使う。
        harness.apply(Self.layout(tabs: [.home], switchable: [Self.bob.renamed("ボブ"), .local]))
        #expect(harness.arrangement.isShowing(Self.bob))
        #expect(harness.arrangement.selectedNavigation === navigation)
        harness.apply(Self.layout(tabs: [.home, Self.bob.renamed("ボブ")], switchable: [.local]))
        #expect(harness.arrangement.isShowing(Self.bob))
        #expect(harness.arrangement.selectedNavigation === navigation)
    }

    /// 選んでいるタブをもう一度押すと、奥に開いた画面から最初の画面へ戻す。タブの中身は入れ物に入れているので、UIKitに任せず戻す。
    /// タブに並べた項目も、切り替えタブの中の項目も同じ。
    @Test func reselectingTabPopsToRoot() throws {
        let harness = try Harness(Self.layout(tabs: [.home], switchable: [.local]))
        let delegate = TabReselectionDelegate(reselectRoot: { _ in }, navigation: { [arrangement = harness.arrangement] in arrangement.navigation(for: $0) }) { _ in }
        let controller = harness.arrangement.tabBarController

        for item in [TabItem.home, .local] {
            harness.arrangement.show(item)
            let navigation = try #require(harness.navigations[item])
            navigation.pushViewController(UIViewController(), animated: false)
            harness.window.layoutIfNeeded()
            let selected = try #require(controller.selectedTab)

            #expect(delegate.tabBarController(controller, shouldSelectTab: selected) == false)
            #expect(navigation.viewControllers.count == 1)
        }
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

    /// 横幅の広いタブバーでは、境目より下の項目も直接並べて切り替えタブを出さない。
    /// 切り替えタブで最後に選んだ項目は、出していない間も覚えておき、狭くなって切り替えタブに戻ったらその項目で開く。
    @Test func regularWidthPadPlacesSwitchableDirectlyAndKeepsSwitchSelection() throws {
        let harness = try Harness(Self.layout(tabs: [.home, .notifications, .local, .federated], switchable: [.bookmarks, .favourites], disabled: [.local, .federated]))
        var saved: [TabItem] = []
        harness.arrangement.onSwitchSelectionChange = { saved.append($0) }
        harness.arrangement.show(.favourites)
        harness.arrangement.show(.home)

        harness.arrangement.tabBarController.traitOverrides.userInterfaceIdiom = .pad
        harness.arrangement.tabBarController.traitOverrides.horizontalSizeClass = .regular
        harness.window.layoutIfNeeded()
        #expect(harness.tabIdentifiers == ["home", "notifications", "bookmarks", "favourites"])
        #expect(harness.arrangement.isShowing(.home))

        harness.arrangement.tabBarController.traitOverrides.horizontalSizeClass = .compact
        harness.window.layoutIfNeeded()
        #expect(harness.tabIdentifiers == ["home", "notifications", TabArrangement.switchIdentifier])
        #expect(harness.switchTitle == "お気に入り")
        #expect(!saved.contains(.bookmarks))
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

    /// サーバーから消えた項目は、並びから外れたら作ったナビゲーションを捨てる。同じ項目がまた並びに出たら作り直し、止めたタイムラインを使い回さない。
    @Test func forgottenItemIsMadeAgainWhenPlacedAgain() throws {
        let harness = try Harness(Self.layout(tabs: [.home, Self.friends], switchable: [.local]))
        #expect(harness.made.made.filter { $0 == Self.friends }.count == 1)

        harness.arrangement.forget([Self.friends])
        harness.apply(Self.layout(tabs: [.home], switchable: [.local], disabled: []).withoutItem(Self.friends))
        harness.apply(Self.layout(tabs: [.home, Self.friends], switchable: [.local]))

        #expect(harness.made.made.filter { $0 == Self.friends }.count == 2)
    }

    /// アイコンを渡した項目は、タブ、切り替えタブ、見出しのメニューで記号の代わりにそのアイコンを出す。届いたら、作ってあるタブも出し直す。
    @Test func iconReplacesSymbolOnceGiven() throws {
        let harness = try Harness(Self.layout(tabs: [.home, Self.bob], switchable: [Self.carol, .local]))
        let icons: [TabItem: ProfileTabIcons.Icon] = [Self.bob: Self.icon(.red), Self.carol: Self.icon(.blue)]
        var given: Set<TabItem> = []
        harness.arrangement.icon = { given.contains($0) ? icons[$0] : nil }
        let bobTab = try #require(harness.arrangement.tabBarController.tabs.first { $0.identifier == Self.bob.rawValue })
        let switchTab = try #require(harness.arrangement.tabBarController.tabs.first { $0.identifier == TabArrangement.switchIdentifier })
        #expect(bobTab.image?.renderingMode != .alwaysOriginal)

        given = [Self.bob, Self.carol]
        harness.arrangement.refreshIcons()

        #expect(bobTab.image === icons[Self.bob]?.tab)
        #expect(switchTab.image === icons[Self.carol]?.tab)
        if #available(iOS 26.1, *) {
            #expect(bobTab.selectedImage === icons[Self.bob]?.selectedTab)
        }
        let root = try #require(harness.navigations[Self.carol]?.viewControllers.first)
        let menu = try #require(root.navigationItem.titleMenuProvider?([]))
        // 「カスタマイズ」を出す設定（端末の設定で、既定は出す）では、見出しのメニューのタイムラインの項目は最初のまとまりに入る。
        let timelines = (menu.children.first as? UIMenu)?.children ?? menu.children
        let images = timelines.compactMap { ($0 as? UIAction)?.image }
        #expect(images.first === icons[Self.carol]?.menu)
        #expect(images.last?.renderingMode != .alwaysOriginal)
    }

    /// モノトーンとグレーでは、タブのアイコンを本文の色の濃淡で描くため、色を付けた記号で渡す。ほかの色では、タブバーの描き方に任せる。
    /// 選んでいるときの画像を渡せないiOS 26.0では、薄くしない。
    @available(iOS 26.1, *)
    @Test(arguments: [AccentColorChoice.monochrome, .gray])
    func colorlessAccentDimsUnselectedSymbols(_ accent: AccentColorChoice) async throws {
        let settings = AppSettings.isolated()
        let harness = try Harness(Self.layout(tabs: [.home, .search], switchable: [.local]), settings: settings)
        let tabs = harness.arrangement.tabBarController.tabs
        #expect(tabs.allSatisfy { $0.image?.renderingMode != .alwaysOriginal })

        settings.accentColor = accent
        try await waitUntil { tabs.allSatisfy { $0.image?.renderingMode == .alwaysOriginal } }
        #expect(tabs.allSatisfy { $0.image?.isSymbolImage == true })
        #expect(tabs.allSatisfy { $0.selectedImage?.renderingMode == .alwaysOriginal })

        settings.accentColor = .blue
        try await waitUntil { tabs.allSatisfy { $0.image?.renderingMode != .alwaysOriginal } }
    }

    /// アクセントカラーを選び直したら、プロフィールのアイコンを読み直して、選んでいるときの縁を新しい色で描かせる。
    @Test func accentColorChangeRequestsIconsAgain() async throws {
        let settings = AppSettings.isolated()
        let harness = try Harness(Self.layout(tabs: [.home, Self.bob], switchable: [.local]), settings: settings)
        var requested: [TabItem] = []
        harness.arrangement.icon = { item in
            requested.append(item)
            return nil
        }

        settings.accentColor = .orange

        try await waitUntil { requested.contains(Self.bob) }
    }

    private static func icon(_ color: UIColor) -> ProfileTabIcons.Icon {
        let image = { UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in
            color.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.withRenderingMode(.alwaysOriginal) }
        return ProfileTabIcons.Icon(tab: image(), selectedTab: image(), menu: image())
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
