/// タブバーに置ける項目。並びは対象のメニューと同じ`MenuLayout`で持ち、「その他」の境目より下の項目は切り替えタブにまとめる。
/// 決まりはdocs/tabs.mdにある。`rawValue`は設定に保存するため、一度使った値は変えない。
public enum TabItem: MenuItemKind {
    case home
    case local
    case federated
    case notifications
    /// 検索。決まりはdocs/search.mdにある。
    case search
    case bookmarks
    case favourites
    /// 予約した投稿のタイムライン。決まりはdocs/tabs.mdの「予約投稿」にある。
    case scheduled
    /// フォローしているハッシュタグのリスト。決まりはdocs/tabs.mdの「フォロー中のハッシュタグ」にある。
    case followedTags
    /// 自分のリスト。`title`は、自分のリストを読む前からタブの名前を出せるよう、並びと一緒に保存する。
    /// 同じ項目かどうかはIDだけで見る。名前が変わっても、並びの中の同じ場所の同じリストとして扱うため。
    case list(id: String, title: String)
    /// ハッシュタグのタイムライン。フォローしているかに関わらず、使う人がこの端末の並びに足す。決まりはdocs/tabs.mdの「ハッシュタグ」にある。
    /// `name`は`#`を除いた名前。`title`は使う人が付けたタブの名前で、空なら`#名前`を出す。
    /// 同じ項目かどうかは、サーバーと同じ決まりでそろえた名前（`Hashtag.normalizedName`）で見る。サーバーは大文字と小文字などを区別しないため。
    case hashtag(name: String, title: String = "")
    /// あるユーザーの、ハッシュタグの付いた投稿。サーバーには覚える仕組みがないため、使う人がこの端末の並びに足す。`name`は`#`を除いた名前。
    /// `acct`は、タブとタイムラインの見出しにハンドルを出すため、並びと一緒に保存する。`title`は使う人が付けたタブの名前で、空なら`#名前`を出す。
    /// 同じ項目かどうかは、アカウントのIDと、ハッシュタグのそろえた名前で見る。
    case accountHashtag(accountID: String, acct: String, name: String, title: String = "")
    /// あるユーザーのプロフィール。ユーザーのハッシュタグと同じく、使う人がこの端末の並びに足す。決まりはdocs/tabs.mdの「プロフィール」にある。
    /// `acct`は、アカウントを読む前からタブの名前を出せるよう、並びと一緒に保存する。`title`は使う人が付けたタブの名前で、空なら`@name`を出す。
    /// 同じ項目かどうかは、アカウントのIDで見る。
    case profile(accountID: String, acct: String, title: String = "")

    /// リストの項目の`rawValue`の頭。`list:<ID>:<名前>`の形で保存する。リストのIDは`:`を含まないため、2つ目の`:`より後ろは名前として読む。
    private static let listPrefix = "list:"
    /// ハッシュタグの項目の`rawValue`の頭。`hashtag:<名前>:<付けた名前>`の形で保存する。ハッシュタグの名前は`:`を含まないため、1つ目の`:`より後ろは付けた名前として読む。
    private static let hashtagPrefix = "hashtag:"
    /// ユーザーのハッシュタグの項目の`rawValue`の頭。`accountHashtag:<ID>:<acct>:<名前>:<付けた名前>`の形で保存する。
    /// ID、`acct`、ハッシュタグの名前は`:`を含まないため、4つ目の`:`より後ろは付けた名前として読む。付けた名前は`:`を含みうるので最後に置く。
    private static let accountHashtagPrefix = "accountHashtag:"
    /// プロフィールの項目の`rawValue`の頭。`profile:<ID>:<acct>:<付けた名前>`の形で保存する。
    /// IDと`acct`は`:`を含まないため、2つ目の`:`より後ろは付けた名前として読む。
    private static let profilePrefix = "profile:"

    /// 決まった項目。リストとハッシュタグは使う人ごとに違うため含まない。既定の並びと、保存した並びに足りない項目を差し込むのに使う。
    public static let allCases: [TabItem] = [.home, .local, .federated, .notifications, .search, .bookmarks, .favourites, .scheduled, .followedTags]

    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.accountHashtagPrefix) {
            let parts = rawValue.dropFirst(Self.accountHashtagPrefix.count).split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, !parts[0].isEmpty, !parts[2].isEmpty else { return nil }
            self = .accountHashtag(accountID: String(parts[0]), acct: String(parts[1]), name: String(parts[2]), title: String(parts[3]))
            return
        }
        if rawValue.hasPrefix(Self.profilePrefix) {
            let parts = rawValue.dropFirst(Self.profilePrefix.count).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            self = .profile(accountID: String(parts[0]), acct: String(parts[1]), title: String(parts[2]))
            return
        }
        if rawValue.hasPrefix(Self.listPrefix) {
            let parts = rawValue.dropFirst(Self.listPrefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let id = parts.first, !id.isEmpty else { return nil }
            self = .list(id: String(id), title: parts.count > 1 ? String(parts[1]) : "")
            return
        }
        if rawValue.hasPrefix(Self.hashtagPrefix) {
            let parts = rawValue.dropFirst(Self.hashtagPrefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { return nil }
            self = .hashtag(name: String(name), title: parts.count > 1 ? String(parts[1]) : "")
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
        case .search: "search"
        case .bookmarks: "bookmarks"
        case .favourites: "favourites"
        case .scheduled: "scheduled"
        case .followedTags: "followed-tags"
        case .list(let id, let title): "\(Self.listPrefix)\(id):\(title)"
        case .hashtag(let name, let title): "\(Self.hashtagPrefix)\(name):\(title)"
        case .accountHashtag(let accountID, let acct, let name, let title): "\(Self.accountHashtagPrefix)\(accountID):\(acct):\(name):\(title)"
        case .profile(let accountID, let acct, let title): "\(Self.profilePrefix)\(accountID):\(acct):\(title)"
        }
    }

    /// 操作の記録に残す名前。リストの名前、ハッシュタグの名前、ハンドル、付けた名前は、何に関心があるかが分かるので含めない（docs/logging.md）。
    /// 状態ダンプと突き合わせられるよう、サーバーが振ったIDは残す。
    public var logName: String {
        switch self {
        case .list(let id, _): "\(Self.listPrefix)\(id)"
        case .hashtag: "hashtag"
        case .accountHashtag(let accountID, _, _, _): "\(Self.accountHashtagPrefix)\(accountID)"
        case .profile(let accountID, _, _): "\(Self.profilePrefix)\(accountID)"
        default: rawValue
        }
    }

    /// 同じ項目かどうかを見る値。リストは名前を含めず、ハッシュタグはそろえた名前で見る。
    private var identity: String {
        switch self {
        case .list(let id, _): "\(Self.listPrefix)\(id)"
        case .hashtag(let name, _): "\(Self.hashtagPrefix)\(Hashtag.normalizedName(name))"
        case .accountHashtag(let accountID, _, let name, _): "\(Self.accountHashtagPrefix)\(accountID):\(Hashtag.normalizedName(name))"
        case .profile(let accountID, _, _): "\(Self.profilePrefix)\(accountID)"
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

    public var isProfile: Bool {
        if case .profile = self { true } else { false }
    }

    /// 使う人がこの端末の並びに足す項目。サーバーから読んで足し直せないため、最初の並びに戻しても残し、使う人が名前を付けられる。
    public var isUserAdded: Bool {
        isHashtag || isAccountHashtag || isProfile
    }

    /// 使う人が付けた名前を`title`に変えた項目。使う人が足す項目でなければ、そのまま返す。
    public func renamed(_ title: String) -> TabItem {
        switch self {
        case .hashtag(let name, _): .hashtag(name: name, title: title)
        case .accountHashtag(let accountID, let acct, let name, _): .accountHashtag(accountID: accountID, acct: acct, name: name, title: title)
        case .profile(let accountID, let acct, _): .profile(accountID: accountID, acct: acct, title: title)
        default: self
        }
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

    /// タブに置ける種類なら、その項目。引用した投稿のタイムラインはタブに置けないのでnil。
    public init?(_ kind: SavedStatusesKind) {
        switch kind {
        case .bookmarks: self = .bookmarks
        case .favourites: self = .favourites
        case .quotes: return nil
        }
    }

    public static let defaultLayout = MenuLayout<TabItem>(defaultElements: [
        .item(.home, isVisible: true),
        .item(.notifications, isVisible: true),
        .more,
        .item(.search, isVisible: true),
        .item(.local, isVisible: true),
        .item(.federated, isVisible: true),
        .item(.favourites, isVisible: true),
        .item(.bookmarks, isVisible: true),
        .item(.followedTags, isVisible: true),
        .item(.scheduled, isVisible: true),
    ])
}

extension MenuLayout where Item == TabItem {
    /// サーバーにあるリストを並びに反映する。決まりはdocs/tabs.mdの「リスト」にある。
    /// まだないリストは無効にして最後のリストの後ろに足し、もうないリストは外し、名前が変わったリストは名前を書き換える。ほかの項目の並びと表示は変えない。
    public func syncingLists(_ lists: [MastodonList]) -> MenuLayout<TabItem> {
        syncing(lists.map { .list(id: $0.id, title: $0.title) }, where: \.isList)
    }

    /// 使う人が足した項目を、有効にして切り替えタブの末尾に入れる。ブックマークやお気に入りを有効にしたときと同じく、ふだん並べているタブを押しのけないため。
    /// 並びにすでにあれば、そのまま返す。
    public func adding(_ item: TabItem) -> MenuLayout<TabItem> {
        guard !contains(item) else { return self }
        return MenuLayout(elements: elements + [.item(item, isVisible: true)])
    }

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

    /// `previous`にあった、使う人が足した項目（ユーザーのハッシュタグとプロフィール）のうち、この並びにないものを、無効にして末尾に足す。
    /// 設定の並びの画面が並びを書くときに、最初の並びに戻して消えた項目を残すのに使う。サーバーから取得して足し直せないため。
    /// 設定の並びで項目を削除するときは、この書き込みを通さずに外す。
    public func keepingUserAddedItems(of previous: MenuLayout<TabItem>) -> MenuLayout<TabItem> {
        addingMissing(previous.elements.compactMap { element in
            if case .item(let item, _) = element, item.isUserAdded { item } else { nil }
        })
    }

    /// 並びにない項目だけを、無効にして末尾に足す。並びにある項目は、外すことも名前を書き換えることもしない。
    /// 最初の並びに戻したときに、リストやハッシュタグを足し直すのに使う。同じアカウントをいくつものウインドウで開いていると、ウインドウごとに読んだリストやハッシュタグが違うことがあり、
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
    /// まだない項目は、無効にして、`belongs`に当てはまる最後の項目のすぐ後ろに足す。最後の項目は外す前の位置で決め、当てはまる項目がなければ末尾に足す。
    private func syncing(_ fetched: [TabItem], where belongs: (TabItem) -> Bool) -> MenuLayout<TabItem> {
        let latest = Dictionary(fetched.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
        var known: Set<TabItem> = []
        var elements: [Element] = []
        var insertionIndex: Int?
        for element in self.elements {
            guard case .item(let item, let isVisible) = element, belongs(item) else {
                elements.append(element)
                continue
            }
            if let current = latest[item] {
                known.insert(item)
                elements.append(.item(current, isVisible: isVisible))
            }
            insertionIndex = elements.count
        }
        let added = fetched.filter { known.insert($0).inserted }.map { Element.item($0, isVisible: false) }
        elements.insert(contentsOf: added, at: insertionIndex ?? elements.count)
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

    /// - Parameter tabBarCapacity: タブバーに並べられるタブの数。切り替えタブも1つに数える。
    ///   nilなら数を限らず、境目より下の項目も直接並べて、切り替えタブを出さない。数を限らない上のタブバーでは、切り替えタブがほかのタブと同じ形で並び、見分けがつかないため。
    ///   境目より上の項目が入りきらなければ、入りきらない分を、境目より下の項目の前に並べて切り替えタブにまとめる。
    ///   UIKitの「その他」は、選んでいるタブ（`selectedTab`）を変えず、中の項目の画面を自分のナビゲーションへ移すため、タブを移れなくなるから。
    public init(layout: MenuLayout<TabItem>, tabBarCapacity: Int?) {
        let groups = layout.groups
        var tabs = groups.main.flatMap(\.items)
        var switchable = groups.more.flatMap(\.items)
        if tabBarCapacity == nil {
            tabs += switchable
            switchable = []
        } else if let tabBarCapacity, tabs.count + (switchable.isEmpty ? 0 : 1) > tabBarCapacity {
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
