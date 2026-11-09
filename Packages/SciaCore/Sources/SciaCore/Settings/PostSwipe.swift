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

/// スワイプのボタンに出す名前を、投稿の行の高さで選ぶ。決まりはdocs/object-actions.mdの「投稿のスワイプ」にある。
public enum PostSwipeLabel {
    /// UIKitは、行が低いと名前をアイコンの横に並べるか消し、これを指定する公開APIがない。次の2つは、iOS 27のシミュレーターで12種類の文字サイズを測った、名前がアイコンの下に並ぶ高さの最大。iOSの更新で境目が上がると横に並ぶ。
    static let twoLineMinimumRowHeight = 85.0
    static let oneLineMinimumRowHeight = 63.0
    /// カプセルの幅は最も長い行で決まり、全角5文字までなら並び全体が同じ幅に揃って、幅402ptの画面に5個入る。
    private static let maximumLineLength = 5
    private static let ellipsis = "…"

    /// 行の高さがこの`rowHeight`のときに出す名前。名前を出さない高さではnil。
    public static func text(for title: String, rowHeight: Double) -> String? {
        if rowHeight >= twoLineMinimumRowHeight { return twoLines(title) }
        if rowHeight >= oneLineMinimumRowHeight { return oneLine(title) }
        return nil
    }

    private static func oneLine(_ title: String) -> String {
        guard title.count > maximumLineLength else { return title }
        return title.prefix(maximumLineLength - 1) + ellipsis
    }

    private static func twoLines(_ title: String) -> String {
        guard title.count > maximumLineLength else { return title }
        guard title.count > maximumLineLength * 2 else {
            let firstLineLength = (title.count + 1) / 2
            return title.prefix(firstLineLength) + "\n" + title.dropFirst(firstLineLength)
        }
        return title.prefix(maximumLineLength) + "\n" + title.dropFirst(maximumLineLength).prefix(maximumLineLength - 1) + ellipsis
    }
}

extension MenuLayout where Item == PostSwipeItem {
    /// スワイプで出すボタン。画面の端の側から並べる順。
    public var swipeItems: [PostSwipeItem] {
        (groups.main + groups.more).flatMap(\.items)
    }
}
