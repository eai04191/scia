public import Foundation

/// プラットフォームに依存しないメニューの木。長押しのメニューの項目の名前、アイコン、押せるか、押したときの操作を、UIKitやAppKitに頼らずに表す。
/// 何をどの順に出すかはSciaCoreでこの木に組み、UIKit（`UIMenu`）やAppKit（`NSMenu`）はこの木を描くだけにする。押された項目の`Command`を受け取って、今の処理を呼ぶ。
/// 決まりはdocs/menus.mdにある。
public struct MenuNode<Command> {
    /// 項目の中身。
    public enum Content {
        /// 押すと`Command`を行う項目。押せない知らせの行のように、行う操作がなければnil。
        case action(Command?)
        /// 名前の付いたサブメニュー。
        case submenu([MenuNode])
        /// 区切り線で分けたまとまり。名前は出さない。`isRow`なら、アイコンと名前を縦に積んだ中くらいの大きさで横に並べる。
        case group([MenuNode], isRow: Bool)
        /// 開いてから中身を読む項目。読む間は読み込み中の行を出し、読み終えたら中身に差し替える。
        case deferred(@MainActor () async -> [MenuNode])
    }

    public var title: String
    /// 名前の下に添える説明。押せない理由や、人数など。
    public var subtitle: String?
    public var icon: MenuIcon?
    /// 押せるか。押せない項目は、薄く出して押せないようにする。
    public var isEnabled: Bool
    /// 取り消せない操作（削除、ブロックなど）。赤く出す。
    public var isDestructive: Bool
    /// 選んでいる状態。チェックマークを付ける。
    public var isSelected: Bool
    public var content: Content

    public init(title: String, subtitle: String? = nil, icon: MenuIcon? = nil, isEnabled: Bool = true, isDestructive: Bool = false, isSelected: Bool = false, content: Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.isSelected = isSelected
        self.content = content
    }

    /// 押すと`command`を行う項目。`command`がなければ押せない。
    public static func action(
        _ title: String,
        subtitle: String? = nil,
        icon: MenuIcon? = nil,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        isSelected: Bool = false,
        _ command: Command?
    ) -> MenuNode {
        MenuNode(title: title, subtitle: subtitle, icon: icon, isEnabled: isEnabled && command != nil, isDestructive: isDestructive, isSelected: isSelected, content: .action(command))
    }

    public static func submenu(_ title: String, subtitle: String? = nil, icon: MenuIcon? = nil, _ children: [MenuNode]) -> MenuNode {
        MenuNode(title: title, subtitle: subtitle, icon: icon, content: .submenu(children))
    }

    public static func group(_ children: [MenuNode], isRow: Bool = false) -> MenuNode {
        MenuNode(title: "", content: .group(children, isRow: isRow))
    }

    public static func deferred(_ load: @escaping @MainActor () async -> [MenuNode]) -> MenuNode {
        MenuNode(title: "", content: .deferred(load))
    }

    /// サブメニューとまとまりの中身。項目と、開いてから読む項目では空。
    public var children: [MenuNode] {
        switch content {
        case .submenu(let children), .group(let children, _): children
        case .action, .deferred: []
        }
    }

    /// 押したときの操作。項目でなければnil。
    public var command: Command? {
        if case .action(let command) = content { command } else { nil }
    }

    /// 中身のまとまりを開いて並べた項目。サブメニューは開かない。
    public var flattenedChildren: [MenuNode] {
        children.flatMap { child -> [MenuNode] in
            if case .group = child.content { return child.flattenedChildren }
            return [child]
        }
    }
}

@MainActor
extension MenuNode {
    /// 操作を別の型に包む。ほかのメニューの中にサブメニューとして置くときに使う。開いてから読む項目は、読んだ中身も包む。
    public func map<T>(_ transform: @escaping @MainActor (Command) -> T) -> MenuNode<T> {
        let content: MenuNode<T>.Content = switch self.content {
        case .action(let command): .action(command.map(transform))
        case .submenu(let children): .submenu(children.map { $0.map(transform) })
        case .group(let children, let isRow): .group(children.map { $0.map(transform) }, isRow: isRow)
        case .deferred(let load): .deferred { await load().map { $0.map(transform) } }
        }
        return MenuNode<T>(title: title, subtitle: subtitle, icon: icon, isEnabled: isEnabled, isDestructive: isDestructive, isSelected: isSelected, content: content)
    }
}

/// メニューの項目のアイコン。描く側が画像にする。
public enum MenuIcon {
    /// SF Symbolsの名前。
    case symbol(String)
    /// 人のアイコン。描く側が読み込み済みの画像を出す。出せなければ`fallbackSymbol`の記号を出し、それもなければアイコンを付けない。
    case avatar(MenuAvatar, fallbackSymbol: String?)
    /// カスタム絵文字の画像。描く側が読み込み済みの画像を出す。出せなければ`fallbackSymbol`の記号を出す。
    case customEmoji(CustomEmoji, fallbackSymbol: String)

    /// 画像を出せなかったときの記号。
    public var symbolName: String? {
        switch self {
        case .symbol(let name): name
        case .avatar(_, let fallback): fallback
        case .customEmoji(_, let fallback): fallback
        }
    }
}

/// アイコンを出す人。
public enum MenuAvatar {
    case user(MenuUser)
    /// 本文や自己紹介のメンションのリンク。相手のIDが分からないため、プロフィールのURLで探す。
    case mentionLink(URL)
}

/// 投稿のメニューの中で、ユーザーのメニューを出す相手。メンションはアカウントの全体を持たないため、IDでプロフィールを開く。
public enum MenuUser: Sendable {
    case account(Account)
    case mention(Mention)

    public var id: String {
        switch self {
        case .account(let account): account.id
        case .mention(let mention): mention.id
        }
    }

    public var acct: String {
        switch self {
        case .account(let account): account.acct
        case .mention(let mention): mention.acct
        }
    }

    /// プロフィールのページのURL。
    public var url: URL? {
        switch self {
        case .account(let account): account.url
        case .mention(let mention): mention.url
        }
    }
}

/// タップや長押しに割り当てた1項目を、メニューと同じ組み方で組んだときに、どう行うか。決まりはdocs/object-actions.mdの「項目を行う」にある。
public enum MenuItemOutcome<Command> {
    /// 押せる項目が1つだけ。メニューを出さずにその操作を行う。
    case perform(Command)
    /// 出す項目がないか、1つだけの項目が押せない。押せない理由があれば添える。
    case unavailable(reason: String?)
    /// サブメニューが1つだけ。名前だけの1行のメニューを出すと、もう1回押さないと中身に届かないため、中身を出す。
    case submenu(MenuNode<Command>)
    /// 項目が2つ以上か、開いてから中身を読む項目。そのままメニューで出す。
    case menu([MenuNode<Command>])

    /// 行えるか。行えなければ、長押しではメニューを出す。
    public var isAvailable: Bool {
        if case .unavailable = self { false } else { true }
    }

    /// `root`は、1項目だけの並び（`MenuLayout.Groups.single`）で組んだメニュー。まとまりは開いて並べる。
    public init(singleItemMenu root: MenuNode<Command>?) {
        let items = root?.flattenedChildren ?? []
        guard let only = items.first else {
            self = .unavailable(reason: nil)
            return
        }
        guard items.count == 1 else {
            self = .menu(items)
            return
        }
        switch only.content {
        case .action(let command):
            if only.isEnabled, let command {
                self = .perform(command)
            } else {
                self = .unavailable(reason: only.subtitle)
            }
        case .submenu:
            self = .submenu(only)
        case .group, .deferred:
            self = .menu(items)
        }
    }
}

extension MenuLayout.Groups {
    /// まとまりごとに区切り線で分けて並べ、「その他」の中身はサブメニューにする。中身のないまとまりと「その他」は出さない。
    /// 横並びのまとまりは、横に並べる印を付ける。項目は「その他」の外のまとまりから順に組む。
    /// - Parameters:
    ///   - elements: 項目ごとの中身。出さない項目は空。
    ///   - group: まとまりを1つの要素にする。2つ目の引数は横並びか。
    ///   - more: 「その他」のサブメニューにする。
    public func arranged<Element>(_ elements: (Item) -> [Element], group: ([Element], Bool) -> Element, more: ([Element]) -> Element) -> [Element] {
        func inline(_ groups: [MenuLayout<Item>.Group]) -> [Element] {
            groups.compactMap { entry in
                let children = entry.items.flatMap(elements)
                return children.isEmpty ? nil : group(children, entry.isRow)
            }
        }
        let mainElements = inline(main)
        let moreElements = inline(self.more)
        guard !moreElements.isEmpty else { return mainElements }
        return mainElements + [more(moreElements)]
    }

    /// メニューの木にする。
    public func nodes<Command>(_ elements: (Item) -> [MenuNode<Command>]) -> [MenuNode<Command>] {
        arranged(elements, group: { MenuNode.group($0, isRow: $1) }, more: { MenuNode.submenu("その他", icon: .symbol("ellipsis.circle"), $0) })
    }
}
