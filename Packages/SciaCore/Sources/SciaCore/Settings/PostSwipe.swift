import Foundation

/// 投稿を左右にスワイプして出すボタン。投稿のメニューの項目か、「メニューを開く」「アクションバーを開く」。決まりはdocs/object-actions.mdの「投稿のスワイプ」にある。
public enum PostSwipeItem: Hashable, Sendable, MenuItemKind, MenuItemPresentable {
    case status(StatusMenuItem)
    /// 投稿を長押ししたときと同じ投稿のメニューを、ボタンから出す。
    case menu
    /// 投稿の下にアクションバーを開閉する。
    case actionBar

    /// 保存する形。「メニューを開く」は`menu`、「アクションバーを開く」は`actionBar`、投稿のメニューの項目は、その項目の`rawValue`をそのまま使う。項目の`rawValue`に`menu`と`actionBar`はない。
    public var rawValue: String {
        switch self {
        case .status(let item): item.rawValue
        case .menu: Self.menuRawValue
        case .actionBar: Self.actionBarRawValue
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case Self.menuRawValue:
            self = .menu
        case Self.actionBarRawValue:
            self = .actionBar
        default:
            guard let item = StatusMenuItem(rawValue: rawValue), Self.isPlaceable(item) else { return nil }
            self = .status(item)
        }
    }

    private static let menuRawValue = "menu"
    private static let actionBarRawValue = "actionBar"

    /// 「カスタマイズ」は投稿のメニューの並びの画面を開く項目で、メニューの中でだけ意味があるので、並べられない。
    private static func isPlaceable(_ item: StatusMenuItem) -> Bool {
        item != .customize
    }

    public static var allCases: [PostSwipeItem] {
        [.menu, .actionBar] + StatusMenuItem.allCases.filter(isPlaceable).map(Self.status)
    }

    /// 既定では何も出さない。「メニューを開く」「アクションバーを開く」のあとに、投稿のメニューの既定の並びの順に並べる。
    public static let defaultLayout: MenuLayout<PostSwipeItem> = {
        let items = StatusMenuItem.defaultLayout.elements.compactMap { element -> PostSwipeItem? in
            guard case .item(let item, _) = element, isPlaceable(item) else { return nil }
            return .status(item)
        }
        return MenuLayout(defaultElements: ([.menu, .actionBar] + items).map { .item($0, isVisible: false) })
    }()

    public var title: String {
        switch self {
        case .status(let item): item.title
        case .menu: "メニューを開く"
        case .actionBar: ObjectAction<StatusMenuItem>.openActionBarTitle
        }
    }

    public var symbolName: String {
        switch self {
        case .status(let item): item.symbolName
        case .menu: "ellipsis"
        case .actionBar: ObjectAction<StatusMenuItem>.openActionBarSymbolName
        }
    }

    /// ボタンを押したときに行う操作。タップや長押しに割り当てた操作と同じ組み方で行う。
    public var action: ObjectAction<StatusMenuItem> {
        switch self {
        case .status(let item): .item(item)
        case .menu: .menu
        case .actionBar: .actionBar
        }
    }

    public static var mainSectionTitle: String { "ボタン" }
    public static var mainSectionNote: String? { "オンにした項目を、上から順に画面の端の側から並べます。" }
    /// スワイプの並びには、区切り線と「その他」の境目を置かない。
    public static var supportsSeparators: Bool { false }
    public static var supportsRowSeparators: Bool { false }
    public static var hasMoreSection: Bool { false }
}

extension MenuLayout where Item == PostSwipeItem {
    /// スワイプで出すボタン。画面の端の側から並べる順。
    public var swipeItems: [PostSwipeItem] {
        (groups.main + groups.more).flatMap(\.items)
    }
}
