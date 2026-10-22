import SciaCore
import UIKit

/// タブの並びから、タブバーと切り替えタブを組む。決まりはdocs/vision.mdの「タブ」にある。
///
/// 項目ごとのナビゲーションは1つずつ作って持ち続け、タブに並べても切り替えタブに入れても同じものを使う。
/// 切り替えても、読み込んだ投稿、スクロール位置、奥に開いた画面がそのまま残る。
@MainActor
final class TabArrangement {
    let tabBarController: UITabBarController
    /// 並びが変わったとき。どの項目を購読するかを決め直す。
    var onPlacementChange: ((TabPlacement) -> Void)?
    /// 選んでいる画面が変わったとき。タブを押したときと、見出しのメニューで切り替えたとき。
    var onShownItemChange: (() -> Void)?
    /// 切り替えタブで開く項目が変わったとき。起動し直しても同じ項目から開けるよう、保存するのに使う。
    var onSwitchSelectionChange: ((TabItem) -> Void)?

    private(set) var placement: TabPlacement
    private let navigations: [TabItem: UINavigationController]
    /// 項目ごとのタブ。一度作ったものを使い続け、並びに合わせて出し入れする。
    private var itemTabs: [TabItem: UITab] = [:]
    /// 切り替えタブの中身と、そのタブ。作り直すときは2つ一緒に作り直す。UIKitは、1つの画面を2つのタブに渡すとアサーションで落ちるため。
    private var switchContainer = SwitchTabViewController()
    private var switchTab: UITab
    /// 切り替えタブで開いている項目。
    private(set) var switchSelection: TabItem?
    private var notificationsBadge: String?
    /// 最初の`apply`で、切り替えタブで開く項目を決めるのに使う。
    private var restoredSwitchSelection: TabItem?

    static let switchIdentifier = "switch"

    /// - Parameter restoring: 前に切り替えタブで開いていた項目。まだ切り替えタブにあれば、そこから開く。
    init(navigations: [TabItem: UINavigationController], placement: TabPlacement, restoring: TabItem? = nil) {
        self.navigations = navigations
        self.placement = placement
        tabBarController = UITabBarController(tabs: [])
        switchTab = Self.makeSwitchTab(for: .home, container: switchContainer)
        restoredSwitchSelection = restoring
        for (item, navigation) in navigations {
            itemTabs[item] = UITab(title: item.title, image: UIImage(systemName: item.symbolName), identifier: item.rawValue) { _ in navigation }
        }
        apply(placement)
    }

    /// すべての項目のナビゲーション。並びにない項目も含む。
    var allNavigations: [UINavigationController] { Array(navigations.values) }

    /// 選んでいるタブで前に出ているナビゲーション。切り替えタブなら、開いている項目のもの。
    var selectedNavigation: UINavigationController? {
        tabBarController.selectedTab.flatMap(navigation(for:))
    }

    func navigation(for tab: UITab) -> UINavigationController? {
        tab === switchTab ? switchContainer.current : tab.viewController as? UINavigationController
    }

    /// 項目を開いて見せているか。切り替えタブなら、開いている項目で見る。
    func isShowing(_ item: TabItem) -> Bool {
        guard let selected = tabBarController.selectedTab else { return false }
        return selected === switchTab ? switchSelection == item : selected === itemTabs[item]
    }

    /// 項目を開く。切り替えタブの中にあれば、切り替えてから切り替えタブを選ぶ。無効にしている項目では何もしない。
    func show(_ item: TabItem) {
        switch placement.location(of: item) {
        case .tab:
            tabBarController.selectedTab = itemTabs[item]
        case .switchTab:
            selectInSwitchTab(item)
            tabBarController.selectedTab = switchTab
        case .disabled:
            return
        }
        onShownItemChange?()
    }

    func setNotificationsBadge(_ value: String?) {
        notificationsBadge = value
        applyBadges()
    }

    func apply(_ placement: TabPlacement) {
        let shown = TabItem.allCases.first(where: isShowing)
        self.placement = placement
        let selection = placement.switchSelection(previous: switchSelection ?? restoredSwitchSelection)
        restoredSwitchSelection = nil
        // 切り替えタブからタブへ移るナビゲーションは、タブに渡す前に入れ物から外す。
        if switchContainer.current !== selection.flatMap({ navigations[$0] }) {
            switchContainer.show(nil)
        }
        var tabs = placement.tabs.compactMap { itemTabs[$0] }
        if let selection {
            if selection != switchSelection {
                renewSwitchTab(for: selection)
            }
            tabs.append(switchTab)
        }
        tabBarController.setTabs(tabs, animated: false)
        if let selection {
            showInSwitchContainer(selection)
        } else {
            switchSelection = nil
        }
        updateTitleMenus()
        applyBadges()
        // 見ていた項目が残っていれば、移った先で開いたままにする。無効にしたなら、UIKitが選んだ先頭のタブのままにする。
        if let shown, placement.location(of: shown) != .disabled {
            show(shown)
        }
        onPlacementChange?(placement)
    }

    /// 切り替えタブの中身を切り替える。名前とアイコンも変わるので、タブを作り直して差し替える。
    private func selectInSwitchTab(_ item: TabItem) {
        guard item != switchSelection else { return }
        let wasSelected = tabBarController.selectedTab === switchTab
        renewSwitchTab(for: item)
        tabBarController.setTabs(tabBarController.tabs.map { $0.identifier == Self.switchIdentifier ? switchTab : $0 }, animated: false)
        showInSwitchContainer(item)
        if wasSelected {
            tabBarController.selectedTab = switchTab
        }
        updateTitleMenus()
    }

    /// 押したときに何が開くかが分かるよう、開いている項目の名前とアイコンで、切り替えタブを作り直す。
    /// 同じタブの`title`を変えると、タブバーの読み上げの名前が前の名前のまま残ることがあり、UITabには読み上げの名前を渡す口がないため。
    /// 中身の入れ物も一緒に作り直す。UIKitは、1つの画面を2つのタブに渡すとアサーションで落ちるため。
    private func renewSwitchTab(for item: TabItem) {
        switchContainer.show(nil)
        switchContainer = SwitchTabViewController()
        switchTab = Self.makeSwitchTab(for: item, container: switchContainer)
        // 新しいタブには、前のタブに出していた通知の未読の数を付け直す。
        applyBadges()
    }

    private func showInSwitchContainer(_ item: TabItem) {
        guard let navigation = navigations[item] else { return }
        switchContainer.show(navigation)
        if switchSelection != item {
            switchSelection = item
            onSwitchSelectionChange?(item)
        }
    }

    private static func makeSwitchTab(for item: TabItem, container: SwitchTabViewController) -> UITab {
        UITab(title: item.title, image: UIImage(systemName: item.symbolName), identifier: switchIdentifier) { _ in container }
    }

    /// 切り替えタブの中の項目だけ、見出しを押して切り替えるメニューにする。
    private func updateTitleMenus() {
        for (item, navigation) in navigations {
            guard let root = navigation.viewControllers.first else { continue }
            guard placement.location(of: item) == .switchTab else {
                root.navigationItem.titleMenuProvider = nil
                continue
            }
            root.navigationItem.titleMenuProvider = { [weak self] _ in
                guard let self else { return nil }
                return UIMenu(children: placement.switchable.map { candidate in
                    UIAction(title: candidate.title, image: UIImage(systemName: candidate.symbolName), state: candidate == switchSelection ? .on : .off) { [weak self] _ in
                        UserAction.selectTab(candidate.rawValue).record()
                        self?.show(candidate)
                    }
                })
            }
        }
    }

    /// 通知の未読の数は、通知を並べているタブに出す。切り替えタブの中なら、開いている項目によらず切り替えタブに出す。
    private func applyBadges() {
        itemTabs[.notifications]?.badgeValue = placement.location(of: .notifications) == .tab ? notificationsBadge : nil
        switchTab.badgeValue = placement.location(of: .notifications) == .switchTab ? notificationsBadge : nil
    }
}

/// 切り替えタブの中身。項目ごとのナビゲーションを子にして、開いている1つだけを出す。
final class SwitchTabViewController: UIViewController {
    private(set) var current: UINavigationController?

    /// 開くナビゲーションを差し替える。nilなら何も出さない。
    func show(_ navigation: UINavigationController?) {
        guard navigation !== current else { return }
        if let current {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        current = navigation
        guard let navigation else { return }
        addChild(navigation)
        navigation.view.frame = view.bounds
        navigation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigation.view)
        navigation.didMove(toParent: self)
        setNeedsStatusBarAppearanceUpdate()
    }

    override var childForStatusBarStyle: UIViewController? { current }
    override var childForStatusBarHidden: UIViewController? { current }
}
