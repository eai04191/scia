/// タブバーに置ける項目。並びは長押しのメニューと同じ`MenuLayout`で持ち、「その他」の境目より下の項目は切り替えタブにまとめる。
/// 決まりはdocs/tabs.mdにある。`rawValue`は設定に保存するため、一度使った値は変えない。
public enum TabItem: MenuItemKind {
    case home
    case local
    case federated
    case notifications
    case bookmarks
    case favourites
    /// 自分のリスト。`title`は、リストの一覧を読む前からタブの名前を出せるよう、並びと一緒に保存する。
    /// 同じ項目かどうかはIDだけで見る。名前が変わっても、並びの中の同じ場所の同じリストとして扱うため。
    case list(id: String, title: String)

    /// リストの項目の`rawValue`の頭。`list:<ID>:<名前>`の形で保存する。リストのIDは`:`を含まないため、2つ目の`:`より後ろは名前として読む。
    private static let listPrefix = "list:"

    /// 決まった項目。リストは使う人ごとに違うため含まない。既定の並びと、保存した並びに足りない項目を差し込むのに使う。
    public static let allCases: [TabItem] = [.home, .local, .federated, .notifications, .bookmarks, .favourites]

    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.listPrefix) {
            let parts = rawValue.dropFirst(Self.listPrefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = parts.first, !id.isEmpty else { return nil }
            self = .list(id: String(id), title: parts.count > 1 ? String(parts[1]) : "")
            return
        }
        guard let item = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = item
    }

    public var rawValue: String {
        switch self {
        case .home: "home"
        case .local: "local"
        case .federated: "federated"
        case .notifications: "notifications"
        case .bookmarks: "bookmarks"
        case .favourites: "favourites"
        case .list(let id, let title): "\(Self.listPrefix)\(id):\(title)"
        }
    }

    /// 同じ項目かどうかを見る値。リストは名前を含めない。
    private var identity: String {
        if case .list(let id, _) = self { "\(Self.listPrefix)\(id)" } else { rawValue }
    }

    public static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    /// リストの名前を差し替える。タブを作り直さずに、名前の変更を並びに書き残すため。
    public func renamed(_ title: String) -> TabItem {
        if case .list(let id, _) = self { .list(id: id, title: title) } else { self }
    }

    public init(_ feed: TimelineFeed) {
        switch feed {
        case .home: self = .home
        case .local: self = .local
        case .federated: self = .federated
        // 同じ項目かどうかはIDだけで見るので、並びの中の場所を探すのに名前は要らない。
        case .list(let id): self = .list(id: id, title: "")
        }
    }

    public init(_ kind: SavedStatusesKind) {
        switch kind {
        case .bookmarks: self = .bookmarks
        case .favourites: self = .favourites
        }
    }

    /// 既定は、切り替えタブを使わず4つを直接並べる。ブックマークとお気に入りは無効にして、切り替えタブの側に置く。
    /// 有効にすると切り替えタブに入る。たまに見る一覧なので、ふだん並べる4つを押しのけないため。
    public static let defaultLayout = MenuLayout<TabItem>(defaultElements: [
        .item(.home, isVisible: true),
        .item(.local, isVisible: true),
        .item(.federated, isVisible: true),
        .item(.notifications, isVisible: true),
        .more,
        .item(.bookmarks, isVisible: false),
        .item(.favourites, isVisible: false),
    ])
}

extension MenuLayout where Item == TabItem {
    /// サーバーのリストの一覧を並びに反映する。決まりはdocs/tabs.mdの「リスト」にある。
    /// まだないリストは無効にして末尾に足し、もうないリストは外し、名前が変わったリストは名前を書き換える。ほかの項目の並びと表示は変えない。
    public func syncingLists(_ lists: [MastodonList]) -> MenuLayout<TabItem> {
        let titles = Dictionary(lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var known: Set<String> = []
        var elements = self.elements.compactMap { element -> Element? in
            guard case .item(.list(let id, _), let isVisible) = element else { return element }
            guard let title = titles[id] else { return nil }
            known.insert(id)
            return .item(.list(id: id, title: title), isVisible: isVisible)
        }
        for list in lists where known.insert(list.id).inserted {
            elements.append(.item(.list(id: list.id, title: list.title), isVisible: false))
        }
        return MenuLayout(elements: elements)
    }

    /// 並びにないリストだけを、無効にして末尾に足す。並びにあるリストは、外すことも名前を書き換えることもしない。
    /// 最初の並びに戻したときに、リストを足し直すのに使う。同じアカウントをいくつものウインドウで開いていると、ウインドウごとに読んだリストが違うことがあり、
    /// 並びが変わるたびに外したり書き換えたりすると、ほかのウインドウの書き換えを打ち消し合い続けるため。
    public func addingMissingLists(_ lists: [MastodonList]) -> MenuLayout<TabItem> {
        let known = Set(listIDs)
        let missing = lists.filter { !known.contains($0.id) }
        guard !missing.isEmpty else { return self }
        return MenuLayout(elements: elements + missing.map { .item(.list(id: $0.id, title: $0.title), isVisible: false) })
    }

    /// 並びにあるリストのID。
    public var listIDs: [String] {
        elements.compactMap { element in
            if case .item(.list(let id, _), _) = element { id } else { nil }
        }
    }
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
    /// 前に開いていた項目は、並びの中の項目で返す。保存しておいたリストの名前は古いことがあるため。
    public func switchSelection(previous: TabItem?) -> TabItem? {
        if let previous, let current = switchable.first(where: { $0 == previous }) { return current }
        return switchable.first
    }
}
