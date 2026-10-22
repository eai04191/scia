import SciaCore
import UIKit

/// タブの並びから、タブバーと切り替えタブを組む。決まりはdocs/tabs.mdにある。
///
/// 項目ごとのナビゲーションは1つずつ作って持ち続け、タブに並べても切り替えタブに入れても同じものを使う。
/// 切り替えても、読み込んだ投稿、スクロール位置、奥に開いた画面がそのまま残る。
/// リストのように数の決まらない項目があるため、ナビゲーションは並びに初めて出たときに作る。
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
    /// 作った項目ごとのナビゲーション。
    private var navigations: [TabItem: UINavigationController] = [:]
    /// 項目のナビゲーションを作る。作れない項目ならnil。
    private let makeNavigation: (TabItem) -> UINavigationController?
    /// 項目ごとのタブ。一度作ったものを使い続け、並びに合わせて出し入れする。
    /// リストの名前が変わっても作り直さないため、タブの名前は起動し直すまで前の名前のまま残る。docs/tabs.mdの「リスト」を参照。
    private var itemTabs: [TabItem: UITab] = [:]
    /// 切り替えタブの中身と、そのタブ。作り直すときは2つ一緒に作り直す。UIKitは、1つの画面を2つのタブに渡すとアサーションで落ちるため。
    private var switchContainer = SwitchTabViewController()
    private var switchTab: UITab
    /// 切り替えタブで開いている項目。
    private(set) var switchSelection: TabItem?
    private var notificationsBadge: String?
    /// サーバーから消えた項目（消したリスト、フォローをやめたハッシュタグ）。並びから外れたら、作ったナビゲーションとタブを捨てる。
    /// 同じ項目がまた並びに出たとき（同じハッシュタグをフォローし直したときなど）に、止めた一覧を使い回さず、作り直すため。
    private var forgotten: Set<TabItem> = []
    /// 最初の`apply`で、切り替えタブで開く項目を決めるのに使う。
    private var restoredSwitchSelection: TabItem?

    static let switchIdentifier = "switch"

    /// - Parameter navigation: 項目のナビゲーションを作る。項目ごとに1回だけ呼ぶ。
    /// - Parameter restoring: 前に切り替えタブで開いていた項目。まだ切り替えタブにあれば、そこから開く。
    init(navigation: @escaping (TabItem) -> UINavigationController?, placement: TabPlacement, restoring: TabItem? = nil) {
        makeNavigation = navigation
        self.placement = placement
        tabBarController = UITabBarController(tabs: [])
        switchTab = Self.makeSwitchTab(for: .home, container: switchContainer)
        restoredSwitchSelection = restoring
        apply(placement)
    }

    /// 作ったすべての項目のナビゲーション。並びから外した項目のものも含む。
    var allNavigations: [UINavigationController] { Array(navigations.values) }

    /// サーバーから消えた項目の、作ったナビゲーションとタブを捨てる。まだ並びにあれば、並びから外れたときに捨てる。
    func forget(_ items: some Sequence<TabItem>) {
        forgotten.formUnion(items)
        discardForgotten()
    }

    private func discardForgotten() {
        for item in forgotten where placement.location(of: item) == .disabled && switchSelection != item {
            navigations[item] = nil
            itemTabs[item] = nil
            forgotten.remove(item)
        }
    }

    /// 項目のナビゲーション。まだなければ作る。
    private func navigation(for item: TabItem) -> UINavigationController? {
        if let navigation = navigations[item] { return navigation }
        guard let navigation = makeNavigation(item) else { return nil }
        navigations[item] = navigation
        return navigation
    }

    /// 項目のタブ。まだなければ作る。
    private func tab(for item: TabItem) -> UITab? {
        if let tab = itemTabs[item] { return tab }
        guard let navigation = navigation(for: item) else { return nil }
        let tab = UITab(title: item.title, image: UIImage(systemName: item.symbolName), identifier: item.rawValue) { _ in navigation }
        itemTabs[item] = tab
        return tab
    }

    /// 開いて見せている項目。切り替えタブなら、開いている項目。
    private var shownItem: TabItem? {
        guard let selected = tabBarController.selectedTab else { return nil }
        if selected === switchTab { return switchSelection }
        return itemTabs.first { $0.value === selected }?.key
    }

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
            tabBarController.selectedTab = tab(for: item)
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
        let shown = shownItem
        self.placement = placement
        let selection = placement.switchSelection(previous: switchSelection ?? restoredSwitchSelection)
        restoredSwitchSelection = nil
        // 切り替えタブからタブへ移るナビゲーションは、タブに渡す前に入れ物から外す。
        if switchContainer.current !== selection.flatMap(navigation(for:)) {
            switchContainer.show(nil)
        }
        var tabs = placement.tabs.compactMap(tab(for:))
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
        discardForgotten()
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
        guard let navigation = navigation(for: item) else { return }
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
