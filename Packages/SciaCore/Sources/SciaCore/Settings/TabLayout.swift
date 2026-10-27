/// タブバーに置ける項目。並びは長押しのメニューと同じ`MenuLayout`で持ち、「その他」の境目より下の項目は切り替えタブにまとめる。
/// 決まりはdocs/tabs.mdにある。`rawValue`は設定に保存するため、一度使った値は変えない。
public enum TabItem: MenuItemKind {
    case home
    case local
    case federated
    case notifications
    case bookmarks
    case favourites
    /// 予約した投稿の一覧。決まりはdocs/tabs.mdの「予約投稿」にある。
    case scheduled
    /// 自分のリスト。`title`は、リストの一覧を読む前からタブの名前を出せるよう、並びと一緒に保存する。
    /// 同じ項目かどうかはIDだけで見る。名前が変わっても、並びの中の同じ場所の同じリストとして扱うため。
    case list(id: String, title: String)
    /// フォローしているハッシュタグ。`name`は`#`を除いた名前。
    /// 同じ項目かどうかは、サーバーと同じ決まりでそろえた名前（`Hashtag.normalizedName`）で見る。サーバーは大文字と小文字などを区別しないため。
    case hashtag(name: String)
    /// あるユーザーの、ハッシュタグの付いた投稿。サーバーには覚える仕組みがないため、使う人がこの端末の並びに足す。`name`は`#`を除いた名前。
    /// `acct`は、タブと一覧の見出しにハンドルを出すため、並びと一緒に保存する。`title`は使う人が付けたタブの名前で、空なら`#名前`を出す。
    /// 同じ項目かどうかは、アカウントのIDと、ハッシュタグのそろえた名前で見る。
    case accountHashtag(accountID: String, acct: String, name: String, title: String = "")

    /// リストの項目の`rawValue`の頭。`list:<ID>:<名前>`の形で保存する。リストのIDは`:`を含まないため、2つ目の`:`より後ろは名前として読む。
    private static let listPrefix = "list:"
    /// ハッシュタグの項目の`rawValue`の頭。`hashtag:<名前>`の形で保存する。
    private static let hashtagPrefix = "hashtag:"
    /// ユーザーのハッシュタグの項目の`rawValue`の頭。`accountHashtag:<ID>:<acct>:<名前>:<付けた名前>`の形で保存する。
    /// ID、`acct`、ハッシュタグの名前は`:`を含まないため、4つ目の`:`より後ろは付けた名前として読む。付けた名前は`:`を含みうるので最後に置く。
    private static let accountHashtagPrefix = "accountHashtag:"

    /// 決まった項目。リストとハッシュタグは使う人ごとに違うため含まない。既定の並びと、保存した並びに足りない項目を差し込むのに使う。
    public static let allCases: [TabItem] = [.home, .local, .federated, .notifications, .bookmarks, .favourites, .scheduled]

    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.accountHashtagPrefix) {
            let parts = rawValue.dropFirst(Self.accountHashtagPrefix.count).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, !parts[0].isEmpty, !parts[2].isEmpty else { return nil }
            self = .accountHashtag(accountID: String(parts[0]), acct: String(parts[1]), name: String(parts[2]), title: String(parts[3]))
            return
        }
        if rawValue.hasPrefix(Self.listPrefix) {
            let parts = rawValue.dropFirst(Self.listPrefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = parts.first, !id.isEmpty else { return nil }
            self = .list(id: String(id), title: parts.count > 1 ? String(parts[1]) : "")
            return
        }
        if rawValue.hasPrefix(Self.hashtagPrefix) {
            let name = rawValue.dropFirst(Self.hashtagPrefix.count)
            guard !name.isEmpty else { return nil }
            self = .hashtag(name: String(name))
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
        case .scheduled: "scheduled"
        case .list(let id, let title): "\(Self.listPrefix)\(id):\(title)"
        case .hashtag(let name): "\(Self.hashtagPrefix)\(name)"
        case .accountHashtag(let accountID, let acct, let name, let title): "\(Self.accountHashtagPrefix)\(accountID):\(acct):\(name):\(title)"
        }
    }

    /// 同じ項目かどうかを見る値。リストは名前を含めず、ハッシュタグはそろえた名前で見る。
    private var identity: String {
        switch self {
        case .list(let id, _): "\(Self.listPrefix)\(id)"
        case .hashtag(let name): "\(Self.hashtagPrefix)\(Hashtag.normalizedName(name))"
        case .accountHashtag(let accountID, _, let name, _): "\(Self.accountHashtagPrefix)\(accountID):\(Hashtag.normalizedName(name))"
        default: rawValue
        }
    }

    public static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    public var isList: Bool {
        if case .list = self { true } else { false }
    }

    public var isHashtag: Bool {
        if case .hashtag = self { true } else { false }
    }

    public var isAccountHashtag: Bool {
        if case .accountHashtag = self { true } else { false }
    }

    public init(_ feed: TimelineFeed) {
        switch feed {
        case .home: self = .home
        case .local: self = .local
        case .federated: self = .federated
        // 同じ項目かどうかはIDだけで見るので、並びの中の場所を探すのに名前は要らない。
        case .list(let id): self = .list(id: id, title: "")
        case .hashtag(let name): self = .hashtag(name: name)
        // 同じ項目かどうかはIDと名前で見るので、並びの中の場所を探すのにハンドルは要らない。
        case .accountHashtag(let accountID, let name): self = .accountHashtag(accountID: accountID, acct: "", name: name)
        }
    }

    public init(_ kind: SavedStatusesKind) {
        switch kind {
        case .bookmarks: self = .bookmarks
        case .favourites: self = .favourites
        }
    }

    /// 既定は、切り替えタブを使わず4つを直接並べる。ブックマーク、お気に入り、予約投稿は無効にして、切り替えタブの側に置く。
    /// 有効にすると切り替えタブに入る。たまに見る一覧なので、ふだん並べる4つを押しのけないため。
    public static let defaultLayout = MenuLayout<TabItem>(defaultElements: [
        .item(.home, isVisible: true),
        .item(.local, isVisible: true),
        .item(.federated, isVisible: true),
        .item(.notifications, isVisible: true),
        .more,
        .item(.bookmarks, isVisible: false),
        .item(.favourites, isVisible: false),
        .item(.scheduled, isVisible: false),
    ])
}

extension MenuLayout where Item == TabItem {
    /// サーバーのリストの一覧を並びに反映する。決まりはdocs/tabs.mdの「リスト」にある。
    /// まだないリストは無効にして末尾に足し、もうないリストは外し、名前が変わったリストは名前を書き換える。ほかの項目の並びと表示は変えない。
    public func syncingLists(_ lists: [MastodonList]) -> MenuLayout<TabItem> {
        syncing(lists.map { .list(id: $0.id, title: $0.title) }, where: \.isList)
    }

    /// フォローしているハッシュタグの一覧を並びに反映する。決まりはdocs/tabs.mdの「フォローしているハッシュタグ」にある。
    /// まだないハッシュタグは無効にして末尾に足し、フォローをやめたハッシュタグは外す。ほかの項目の並びと表示は変えない。
    public func syncingHashtags(_ hashtags: [Hashtag]) -> MenuLayout<TabItem> {
        syncing(hashtags.map { .hashtag(name: $0.name) }, where: \.isHashtag)
    }

    /// 使う人が足した項目を、有効にして切り替えタブの末尾に入れる。ブックマークやお気に入りを有効にしたときと同じく、ふだん並べているタブを押しのけないため。
    /// 並びにすでにあれば、そのまま返す。
    public func adding(_ item: TabItem) -> MenuLayout<TabItem> {
        guard !contains(item) else { return self }
        return MenuLayout(elements: elements + [.item(item, isVisible: true)])
    }

    /// 項目を並びから外す。
    public func removing(_ item: TabItem) -> MenuLayout<TabItem> {
        MenuLayout(elements: elements.filter { element in
            if case .item(let current, _) = element { current != item } else { true }
        })
    }

    /// 並びにある同じ項目を、`item`で置き換える。表示と場所はそのまま残す。使う人がタブの名前を変えたときに使う。
    public func replacing(_ item: TabItem) -> MenuLayout<TabItem> {
        MenuLayout(elements: elements.map { element in
            if case .item(let current, let isVisible) = element, current == item { .item(item, isVisible: isVisible) } else { element }
        })
    }

    /// 並びにある、`item`と同じ項目。名前など、同じ項目かどうかに関わらない値は、並びにある方のもの。
    public func item(matching item: TabItem) -> TabItem? {
        elements.lazy.compactMap { element -> TabItem? in
            if case .item(let current, _) = element, current == item { current } else { nil }
        }.first
    }

    public func contains(_ item: TabItem) -> Bool {
        elements.contains { element in
            if case .item(let current, _) = element { current == item } else { false }
        }
    }

    /// `previous`にあったユーザーのハッシュタグのうち、この並びにないものを、無効にして末尾に足す。
    /// 設定の並びの画面では項目を消せず、ユーザーのハッシュタグが並びから消えるのは最初の並びに戻したときだけなので、そのときに残すのに使う。
    /// サーバーから取得して足し直せないため。
    public func keepingAccountHashtags(of previous: MenuLayout<TabItem>) -> MenuLayout<TabItem> {
        addingMissing(previous.elements.compactMap { element in
            if case .item(let item, _) = element, item.isAccountHashtag { item } else { nil }
        })
    }

    /// 並びにない項目だけを、無効にして末尾に足す。並びにある項目は、外すことも名前を書き換えることもしない。
    /// 最初の並びに戻したときに、リストやハッシュタグを足し直すのに使う。同じアカウントをいくつものウインドウで開いていると、ウインドウごとに読んだ一覧が違うことがあり、
    /// 並びが変わるたびに外したり書き換えたりすると、ほかのウインドウの書き換えを打ち消し合い続けるため。
    public func addingMissing(_ items: [TabItem]) -> MenuLayout<TabItem> {
        let known = Set(elements.compactMap { element -> TabItem? in
            if case .item(let item, _) = element { item } else { nil }
        })
        var seen: Set<TabItem> = []
        let missing = items.filter { !known.contains($0) && seen.insert($0).inserted }
        guard !missing.isEmpty else { return self }
        return MenuLayout(elements: elements + missing.map { .item($0, isVisible: false) })
    }

    /// `belongs`に当てはまる項目を、サーバーから取得した`fetched`にそろえる。並びにある項目は、読んだ項目で置き換えて名前を新しくし、表示はそのまま残す。
    private func syncing(_ fetched: [TabItem], where belongs: (TabItem) -> Bool) -> MenuLayout<TabItem> {
        let latest = Dictionary(fetched.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
        var known: Set<TabItem> = []
        var elements = self.elements.compactMap { element -> Element? in
            guard case .item(let item, let isVisible) = element, belongs(item) else { return element }
            guard let current = latest[item] else { return nil }
            known.insert(item)
            return .item(current, isVisible: isVisible)
        }
        for item in fetched where known.insert(item).inserted {
            elements.append(.item(item, isVisible: false))
        }
        return MenuLayout(elements: elements)
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

    /// 横幅の狭いタブバーに、UIKitが「その他」を出さずに並べられるタブの数。
    public static let compactTabBarCapacity = 5

    /// - Parameter tabBarCapacity: タブバーに並べられるタブの数。切り替えタブも1つに数える。nilなら数を限らない。
    ///   境目より上の項目が入りきらなければ、入りきらない分を、境目より下の項目の前に並べて切り替えタブにまとめる。
    ///   UIKitの「その他」は、選んでいるタブ（`selectedTab`）を変えず、中の項目の画面を自分のナビゲーションへ移すため、タブを移れなくなるから。
    public init(layout: MenuLayout<TabItem>, tabBarCapacity: Int?) {
        let groups = layout.groups
        var tabs = groups.main.flatMap(\.items)
        var switchable = groups.more.flatMap(\.items)
        if let tabBarCapacity, tabs.count + (switchable.isEmpty ? 0 : 1) > tabBarCapacity {
            let kept = tabBarCapacity - 1
            switchable = Array(tabs[kept...]) + switchable
            tabs = Array(tabs[..<kept])
        }
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
