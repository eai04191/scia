import Foundation

/// アクションバーに並べるボタン。投稿のメニューの項目か、投稿のメニューを開く「メニュー」。決まりはdocs/post-action-bar.mdにある。
public enum PostActionBarItem: Hashable, Sendable, MenuItemKind, MenuItemPresentable {
    case status(StatusMenuItem)
    /// 投稿を長押ししたときと同じ投稿のメニューを、ボタンから出す。
    case menu

    /// 保存する形。「メニュー」は`menu`、投稿のメニューの項目は、その項目の`rawValue`をそのまま使う。項目の`rawValue`に`menu`はない。
    public var rawValue: String {
        switch self {
        case .status(let item): item.rawValue
        case .menu: Self.menuRawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue == Self.menuRawValue {
            self = .menu
        } else if let item = StatusMenuItem(rawValue: rawValue), Self.isPlaceable(item) {
            self = .status(item)
        } else {
            return nil
        }
    }

    private static let menuRawValue = "menu"

    /// 「カスタマイズ」は投稿のメニューの並びの画面を開く項目で、メニューの中でだけ意味があるので、並べられない。
    private static func isPlaceable(_ item: StatusMenuItem) -> Bool {
        item != .customize
    }

    public static var allCases: [PostActionBarItem] {
        [.menu] + StatusMenuItem.allCases.filter(isPlaceable).map(Self.status)
    }

    /// 既定は返信、ブースト、お気に入り、ブックマーク、メニューを出し、残りの項目は投稿のメニューの既定の並びの順に、出さずに並べる。
    public static let defaultLayout: MenuLayout<PostActionBarItem> = {
        let shown: [PostActionBarItem] = [.status(.reply), .status(.reblog), .status(.favourite), .status(.bookmark), .menu]
        let rest = StatusMenuItem.defaultLayout.elements.compactMap { element -> PostActionBarItem? in
            guard case .item(let item, _) = element, isPlaceable(item) else { return nil }
            let barItem = PostActionBarItem.status(item)
            return shown.contains(barItem) ? nil : barItem
        }
        return MenuLayout(defaultElements: shown.map { .item($0, isVisible: true) } + rest.map { .item($0, isVisible: false) })
    }()

    public var title: String {
        switch self {
        case .status(let item): item.title
        case .menu: "メニュー"
        }
    }

    public var symbolName: String {
        switch self {
        case .status(let item): item.symbolName
        case .menu: "ellipsis"
        }
    }

    /// ボタンを長押ししたときに出すメニューの項目。空ならメニューを出さない。決まりはdocs/post-action-bar.mdの「ボタン」にある。
    public var longPressItems: [StatusMenuItem] {
        switch self {
        case .status(.reblog): [.reblogWithVisibility, .quote, .rebloggedBy]
        case .status(.favourite): [.favouritedBy]
        default: []
        }
    }

    public static var mainSectionTitle: String { "アクションバー" }
    /// アクションバーの並びには、区切り線と「その他」の境目を置かない。
    public static var supportsSeparators: Bool { false }
    public static var supportsRowSeparators: Bool { false }
    public static var hasMoreSection: Bool { false }
}

extension MenuLayout where Item == PostActionBarItem {
    /// アクションバーに並べるボタン。左から並べる順。
    public var actionBarItems: [PostActionBarItem] {
        (groups.main + groups.more).flatMap(\.items)
    }

    /// アクションバーを出している投稿の長押しのメニューから除く項目。
    /// - Parameters:
    ///   - barItems: アクションバーに並べた項目を除くか。
    ///   - longPressItems: アクションバーに並べたボタンの、長押しで出す項目を除くか。
    public func itemsRemovedFromMenu(barItems: Bool, longPressItems: Bool) -> Set<StatusMenuItem> {
        var removed = Set<StatusMenuItem>()
        for item in actionBarItems {
            if barItems, case .status(let statusItem) = item {
                removed.insert(statusItem)
            }
            if longPressItems {
                removed.formUnion(item.longPressItems)
            }
        }
        return removed
    }
}

/// アクションバーの1つのボタンの中身。投稿の状態と設定から決める。
public struct PostActionBarButton: Equatable, Sendable {
    /// した状態を示す色。
    public enum Tint: Equatable, Sendable {
        case none
        /// ブーストした。光と同じ色で描く。
        case reblog
        /// お気に入りした。光と同じ色で描く。
        case favourite
        /// ブックマークした。
        case bookmark
    }

    public let item: PostActionBarItem
    public let title: String
    public let symbolName: String
    /// アイコンの右に添える件数。添えなければnil。
    public let count: Int?
    /// した状態か。状態を持たない項目ではfalse。
    public let isOn: Bool
    public let tint: Tint
    /// 押して行えるか。行えなければ薄く描き、押すとその対象では行えないことを知らせる。
    public let isAvailable: Bool

    public init(item: PostActionBarItem, title: String, symbolName: String, count: Int?, isOn: Bool, tint: Tint, isAvailable: Bool) {
        self.item = item
        self.title = title
        self.symbolName = symbolName
        self.count = count
        self.isOn = isOn
        self.tint = tint
        self.isAvailable = isAvailable
    }

    /// アイコンの右に添える件数の文字。1万より小さければ桁区切りで出し、1万からは「1.2万」「123万」のように万、億、兆の単位で縮める。
    /// 単位の前の整数の部分はすべて出し、整数の部分が1桁のときだけ小数を1桁添える。
    /// 縮めると正確な数は出ないので、正確な数は読み上げと、投稿のメニューの「お気に入りした人」などで見せる。
    public static func countText(_ count: Int) -> String {
        guard count >= 10_000 else { return count.formatted(.number.locale(countLocale)) }
        // 日本語の数の書き方で縮めたときの単位（万、億、兆）。小数を添えるかを、実際に出す単位で決める。
        let unit = [1_000_000_000_000.0, 100_000_000.0].first { Double(count) >= $0 } ?? 10_000.0
        let fraction = Double(count) / unit < 10 ? 1 : 0
        return count.formatted(.number.notation(.compactName).locale(countLocale).precision(.fractionLength(0...fraction)))
    }

    /// 万と億で縮めるため、端末の言語によらず日本語の数の書き方にする。アプリの文言は日本語だけなので、件数もそれに揃える。
    private static let countLocale = Locale(identifier: "ja_JP")

    /// 投稿のボタン。
    /// - Parameters:
    ///   - shown: 表示している投稿。ブーストなら、ブーストされた投稿。
    ///   - showsCounts: 返信、ブースト、お気に入りに件数を添えるか。
    ///   - isAvailable: 投稿のメニューの項目を、いま押して行えるか。メニューと同じ組み方で決める。
    public static func buttons(for shown: Status, items: [PostActionBarItem], showsCounts: Bool, isAvailable: (StatusMenuItem) -> Bool) -> [PostActionBarButton] {
        items.map { item in
            guard case .status(let statusItem) = item else {
                return PostActionBarButton(item: item, title: item.title, symbolName: item.symbolName, count: nil, isOn: false, tint: .none, isAvailable: true)
            }
            let state = State(statusItem, shown: shown)
            let count = showsCounts ? state.count.flatMap { $0 > 0 ? $0 : nil } : nil
            return PostActionBarButton(
                item: item,
                title: item.title,
                symbolName: state.isOn ? state.onSymbolName ?? item.symbolName : item.symbolName,
                count: count,
                isOn: state.isOn,
                tint: state.isOn ? state.tint : .none,
                isAvailable: isAvailable(statusItem)
            )
        }
    }

    /// 状態と件数を持つ項目の、今の状態。ほかの項目は、状態も件数も持たない。
    private struct State {
        var isOn = false
        var count: Int?
        var tint = Tint.none
        /// した状態の記号。塗りの記号がなければnilで、記号はそのまま色だけで示す。
        var onSymbolName: String?

        init(_ item: StatusMenuItem, shown: Status) {
            switch item {
            case .reply:
                count = shown.repliesCount
            case .reblog:
                isOn = shown.reblogged
                count = shown.reblogsCount
                tint = .reblog
            case .favourite:
                isOn = shown.favourited
                count = shown.favouritesCount
                tint = .favourite
                onSymbolName = "star.fill"
            case .bookmark:
                isOn = shown.bookmarked
                tint = .bookmark
                onSymbolName = "bookmark.fill"
            default:
                break
            }
        }
    }
}
