/// 対象をタップや長押ししたときに行う操作。決まりはdocs/object-actions.mdにある。
public enum ObjectAction<Item: MenuItemKind>: Hashable, Sendable {
    /// その対象のメニューを開く。
    case menu
    /// その対象のメニューの項目を、メニューを出さずに行う。
    case item(Item)

    /// 設定に保存する形。メニューは`menu`、項目は`item:<rawValue>`。
    public var token: String {
        switch self {
        case .menu: "menu"
        case .item(let item): "item:\(item.rawValue)"
        }
    }

    /// 保存した形から読む。知らない形と、なくなった項目ならnil。
    public init?(token: String) {
        if token == "menu" {
            self = .menu
            return
        }
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "item", let item = Item(rawValue: parts[1]) else { return nil }
        self = .item(item)
    }
}

/// 操作を選べる手つき。
public enum ObjectTrigger: Sendable {
    case tap
    case longPress
}

/// 1つの対象のタップと長押しの操作。
public struct ObjectActions<Item: MenuItemKind>: Hashable, Sendable {
    public var tap: ObjectAction<Item>
    public var longPress: ObjectAction<Item>

    public init(tap: ObjectAction<Item>, longPress: ObjectAction<Item>) {
        self.tap = tap
        self.longPress = longPress
    }

    public subscript(trigger: ObjectTrigger) -> ObjectAction<Item> {
        get {
            switch trigger {
            case .tap: tap
            case .longPress: longPress
            }
        }
        set {
            switch trigger {
            case .tap: tap = newValue
            case .longPress: longPress = newValue
            }
        }
    }

    /// タップか長押しで、メニューを開けるか。開けなければ、メニューにしかない操作に届かない。
    public var opensMenu: Bool {
        tap == .menu || longPress == .menu
    }

    /// 設定に保存する形。タップ、長押しの順に並べる。
    public var tokens: [String] {
        [tap.token, longPress.token]
    }

    /// 保存した形から読む。読めない操作（なくなった項目など）は、その操作だけ既定に戻す。
    public init(tokens: [String], default defaultValue: Self) {
        tap = tokens.first.flatMap(ObjectAction.init(token:)) ?? defaultValue.tap
        longPress = tokens.dropFirst().first.flatMap(ObjectAction.init(token:)) ?? defaultValue.longPress
    }
}

/// タップと長押しの操作を選べる対象の、メニューの項目の種類。
public protocol ObjectActionItem: MenuItemKind {
    /// その対象の主な操作。タップの既定にし、今のタップの処理で行う。決まりはdocs/object-actions.mdの「対象」にある。
    static var primaryItem: Self { get }
}

extension ObjectActions where Item: ObjectActionItem {
    /// 既定。タップで主な操作を行い、長押しでメニューを開く。
    public static var standard: Self {
        ObjectActions(tap: .item(Item.primaryItem), longPress: .menu)
    }

    /// `trigger`に、主な操作を選んでいるか。
    public func performsPrimary(_ trigger: ObjectTrigger) -> Bool {
        self[trigger] == .item(Item.primaryItem)
    }
}

/// 投稿と通知はどちらも、スレッドを開く。
extension StatusMenuItem: ObjectActionItem {
    public static var primaryItem: Self { .openThread }
}

extension UserMenuItem: ObjectActionItem {
    public static var primaryItem: Self { .profile }
}

/// 開く場所の設定に従って開く。
extension LinkMenuItem: ObjectActionItem {
    public static var primaryItem: Self { .openInBrowser }
}

extension HashtagMenuItem: ObjectActionItem {
    public static var primaryItem: Self { .timeline }
}

extension MediaMenuItem: ObjectActionItem {
    public static var primaryItem: Self { .open }
}
