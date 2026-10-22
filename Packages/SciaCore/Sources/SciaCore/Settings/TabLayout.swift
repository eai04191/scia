/// タブバーに置ける項目。並びは長押しのメニューと同じ`MenuLayout`で持ち、「その他」の境目より下の項目は切り替えタブにまとめる。
/// 決まりはdocs/tabs.mdにある。`rawValue`は設定に保存するため、一度使った値は変えない。
public enum TabItem: String, MenuItemKind {
    case home
    case local
    case federated
    case notifications

    public init(_ feed: TimelineFeed) {
        switch feed {
        case .home: self = .home
        case .local: self = .local
        case .federated: self = .federated
        }
    }

    /// 既定は、切り替えタブを使わず4つを直接並べる。
    public static let defaultLayout = MenuLayout<TabItem>(defaultElements: [
        .item(.home, isVisible: true),
        .item(.local, isVisible: true),
        .item(.federated, isVisible: true),
        .item(.notifications, isVisible: true),
        .more,
    ])
}

/// 項目の、タブと切り替えタブへの振り分け。
public struct TabPlacement: Equatable, Sendable {
    public enum Location: Equatable, Sendable {
        /// タブバーに直接並ぶ。
        case tab
        /// 切り替えタブの中にある。
        case switchTab
        /// 設定で無効にしている。
        case disabled
    }

    /// タブバーに直接並べる項目。並びの順。
    public let tabs: [TabItem]
    /// 切り替えタブにまとめる項目。並びの順。空なら切り替えタブを出さない。
    public let switchable: [TabItem]

    public init(layout: MenuLayout<TabItem>) {
        let groups = layout.groups
        let tabs = groups.main.flatMap(\.items)
        let switchable = groups.more.flatMap(\.items)
        if tabs.isEmpty, switchable.isEmpty {
            // 設定画面では最後の1つを無効にできないので、保存した値を手で壊したときにしか起きない。
            // タブバーを空にはできないため、ホームだけを並べる。
            self.tabs = [.home]
            self.switchable = []
        } else {
            self.tabs = tabs
            self.switchable = switchable
        }
    }

    public func location(of item: TabItem) -> Location {
        if tabs.contains(item) { .tab } else if switchable.contains(item) { .switchTab } else { .disabled }
    }

    /// 切り替えタブで開く項目。前に開いていた項目がまだ切り替えタブにあればそれを、なければ先頭を開く。切り替えタブがなければnil。
    public func switchSelection(previous: TabItem?) -> TabItem? {
        if let previous, switchable.contains(previous) { return previous }
        return switchable.first
    }
}
