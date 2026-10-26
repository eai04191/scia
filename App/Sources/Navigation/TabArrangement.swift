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
    /// 使う人が決めた並び。タブバーに並べられる数が変わったら、この並びから振り分け直す。
    private var layout: MenuLayout<TabItem>
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
    /// 切り替えタブの長押しで出すメニュー。iOS 27以降だけ付ける。
    private(set) var switchTabMenu: SwitchTabMenuInteraction?

    static let switchIdentifier = "switch"

    /// - Parameter navigation: 項目のナビゲーションを作る。項目ごとに1回だけ呼ぶ。
    /// - Parameter restoring: 前に切り替えタブで開いていた項目。まだ切り替えタブにあれば、そこから開く。
    init(navigation: @escaping (TabItem) -> UINavigationController?, layout: MenuLayout<TabItem>, restoring: TabItem? = nil) {
        makeNavigation = navigation
        self.layout = layout
        tabBarController = UITabBarController(tabs: [])
        placement = TabPlacement(layout: layout, tabBarCapacity: Self.tabBarCapacity(for: tabBarController.traitCollection))
        switchTab = Self.makeSwitchTab(for: .home, container: switchContainer)
        restoredSwitchSelection = restoring
        apply(placement)
        if #available(iOS 27.0, *) {
            switchTabMenu = SwitchTabMenuInteraction(on: tabBarController.tabBar, isPlaced: { [weak self] in self?.switchSelection != nil }, menuBottom: { [weak self] in self?.switchMenuBottom }, menu: { [weak self] in self?.switchMenu() })
        }
        // Macで窓の幅を変えたときなど、並べられる数が変わったら振り分け直す。
        tabBarController.registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitUserInterfaceIdiom.self]) { [weak self] (_: UITabBarController, _: UITraitCollection) in
            guard let self else { return }
            apply(self.layout)
        }
    }

    /// タブバーに並べられるタブの数。横幅の広いiPadのタブバーは、上に出て横にスクロールするので数を限らない。
    /// ほかは、UIKitが「その他」を出さずに並べられる数にする。「その他」は、選んでいるタブを変えず、中の項目の画面を自分のナビゲーションへ移すため、Sciaの作りとぶつかる。
    private static func tabBarCapacity(for traits: UITraitCollection) -> Int? {
        traits.userInterfaceIdiom == .pad && traits.horizontalSizeClass == .regular ? nil : TabPlacement.compactTabBarCapacity
    }

    /// 並びを反映する。振り分けが変わらず、タブの名前も変わらなければ、タブバーに触らない。
    func apply(_ layout: MenuLayout<TabItem>) {
        self.layout = layout
        let placement = TabPlacement(layout: layout, tabBarCapacity: Self.tabBarCapacity(for: tabBarController.traitCollection))
        // 名前を変えたユーザーのハッシュタグは、同じ項目のままなので振り分けの変化にならない。リストの名前の変更と違い、使う人が変えたものなので、すぐタブに出す。
        // タブを作り直すかは、並べるときに名前を比べて決める。
        let isRenamed = (placement.tabs + placement.switchable).map(\.rawValue) != (self.placement.tabs + self.placement.switchable).map(\.rawValue)
        if placement != self.placement || isRenamed {
            apply(placement)
        }
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

    private func apply(_ placement: TabPlacement) {
        let shown = shownItem
        self.placement = placement
        // 使う人が名前を変えたユーザーのハッシュタグは、作ってあるタブを、新しい名前で作り直す。無効にしている間に変えた名前も、有効に戻したときに出す。
        // 同じタブの`title`を変えると、タブバーの読み上げの名前が前の名前のまま残ることがあるため、作り直して差し替える。
        for item in placement.tabs where item.isAccountHashtag && itemTabs[item].map({ $0.title != item.title }) == true {
            itemTabs[item] = nil
        }
        if let current = switchSelection, let item = placement.switchable.first(where: { $0 == current }), item.isAccountHashtag, item.title != switchTab.title {
            switchSelection = item
            renewSwitchTab(for: item)
        }
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
        // 切り替えタブを目立たせる。iOS 27では、検索タブと同じく右端に切り離した丸いボタンで描かれ、名前は出ずアイコンだけになる。
        if #available(iOS 27.0, *) {
            tabBarController.prominentTabIdentifier = selection == nil ? nil : Self.switchIdentifier
        }
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
            root.navigationItem.titleMenuProvider = { [weak self] _ in self?.switchMenu() }
        }
    }

    /// 切り替えタブの長押しのメニューの下端（ウィンドウの座標）。投稿欄の下端とそろえる。投稿欄と同じく、タブバーの上の領域の下端から余白を空けた位置。
    private var switchMenuBottom: CGFloat? {
        guard let view = tabBarController.view, let window = view.window else { return nil }
        let frame = tabBarController.contentLayoutGuide.layoutFrame
        return view.convert(CGPoint(x: frame.minX, y: frame.maxY - InlineComposeController.barSpacing), to: window).y
    }

    /// 切り替えタブの中の項目から選ぶメニュー。見出しと、切り替えタブの長押しで出す。
    private func switchMenu() -> UIMenu {
        UIMenu(children: placement.switchable.map { candidate in
            UIAction(title: candidate.title, image: UIImage(systemName: candidate.symbolName), state: candidate == switchSelection ? .on : .off) { [weak self] _ in
                UserAction.selectTab(candidate.rawValue).record()
                self?.show(candidate)
            }
        })
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

/// 切り替えタブを長押ししたときに、中の項目から選ぶメニューを出す。見出しまで手を伸ばさずに切り替えるため。
///
/// UIKitのタブには長押しを受け取る仕組みも、タブのボタンの位置を知る仕組みもないため、タブバーに付けて、ボタンの並び方から見分ける。
/// iOS 27のタブバーは、普通のタブを並べたカプセルと、目立たせたタブ1つを入れた丸を、別々のビューとしてタブバーの直下に置く。
/// そこで、直下のビューのうち行の終わりの側の端にあるものが正方形なら、それを切り替えタブのボタンとみなす。
/// 読み上げの名前では見分けない。VoiceOverなどが動いていない実機では、タブのボタンに名前が入っておらず、メニューが出なかったため。
/// iOSの更新で並び方が変わったら、メニューは出ず、長押しはふつうのタップに戻る。
@MainActor
final class SwitchTabMenuInteraction: NSObject, UIContextMenuInteractionDelegate {
    private weak var tabBar: UIView?
    /// 切り替えタブを並べているか。
    private let isPlaced: @MainActor () -> Bool
    private let menu: @MainActor () -> UIMenu?
    /// メニューの下端に許す、いちばん下の位置（ウィンドウの座標）。
    private let menuBottom: @MainActor () -> CGFloat?
    /// compactのメニューは位置を渡せないため、出たあとに投稿欄の下端より上へ移す。
    private let positioner = ContextMenuPositioner()
    /// メニューを出している切り替えタブのボタン。
    private weak var button: UIView?

    init(on tabBar: UIView, isPlaced: @escaping @MainActor () -> Bool, menuBottom: @escaping @MainActor () -> CGFloat?, menu: @escaping @MainActor () -> UIMenu?) {
        self.tabBar = tabBar
        self.isPlaced = isPlaced
        self.menuBottom = menuBottom
        self.menu = menu
        super.init()
        tabBar.addInteraction(CompactContextMenuInteraction(delegate: self))
    }

    /// 長押しした場所（タブバーの座標）が切り替えタブのボタンなら、そのボタン。
    func switchTabButton(at location: CGPoint) -> UIView? {
        guard let tabBar, isPlaced() else { return nil }
        let groups = tabBar.subviews.filter { !$0.isHidden && $0.alpha > 0 && !$0.bounds.isEmpty }
        guard groups.count >= 2 else { return nil }
        let isRightToLeft = tabBar.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let trailing = isRightToLeft ? groups.min { $0.frame.minX < $1.frame.minX } : groups.max { $0.frame.maxX < $1.frame.maxX }
        guard let trailing, abs(trailing.bounds.width - trailing.bounds.height) < 1, trailing.frame.contains(location) else { return nil }
        return trailing
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let button = switchTabButton(at: location), let menu = menu() else { return nil }
        self.button = button
        positioner.prepare(in: tabBar?.window)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        positioner.menuWillAppear(bottomLimit: menuBottom)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration, animator: (any UIContextMenuInteractionAnimating)?) {
        positioner.menuWillEnd()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview
    }

    /// ボタンの場所に置いた、ボタンと同じ大きさの透明な丸。メニューはここから開く。
    /// ボタンそのものを渡すと、UIKitがメニューを出している間ボタンを隠し、押している間ボタンが消えたため、別のビューを渡す。
    private var preview: UITargetedPreview? {
        guard let tabBar, let button, button.window != nil else { return nil }
        let circle = UIView(frame: button.bounds)
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(ovalIn: circle.bounds)
        parameters.backgroundColor = .clear
        parameters.shadowPath = UIBezierPath()
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: tabBar)
        return UITargetedPreview(view: circle, parameters: parameters, target: UIPreviewTarget(container: tabBar, center: center))
    }
}

/// 背景を暗くしない、ボタンのメニューと同じ表示（compact）で出すコンテキストメニュー。
/// 長押しの時間と触覚は、投稿などの長押しと同じくUIKitのコンテキストメニューのものを使い、こちらでは数値を決めない。
/// UIKitが表示の形を選ぶときにこのプロパティを読むことに頼っている。iOS 27.0で確かめた。読まなくなったら、背景が暗くなる標準の表示に戻るだけで、メニューは出る。
@MainActor
final class CompactContextMenuInteraction: UIContextMenuInteraction {
    override var menuAppearance: UIContextMenuInteraction.appearance {
        .compact
    }
}
