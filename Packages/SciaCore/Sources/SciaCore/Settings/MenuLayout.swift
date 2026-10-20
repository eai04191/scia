/// 長押しのメニューの項目の種類。対象（投稿、ユーザー）ごとに1つ作る。
/// `rawValue`は設定に保存するため、一度使った値は変えない。
public protocol MenuItemKind: RawRepresentable<String>, CaseIterable, Hashable, Sendable {
    /// 既定の並び。項目を足すときは、ここにも足す。足した項目を保存済みの並びのどこに入れるかも、この並びで決まる。
    static var defaultLayout: MenuLayout<Self> { get }
}

/// 長押しのメニューの並び。項目、区切り線、「その他」の境目を1本に並べる。決まりはdocs/menus.mdにある。
public struct MenuLayout<Item: MenuItemKind>: Equatable, Sendable {
    public enum Element: Hashable, Sendable {
        /// 非表示にした項目も、同じ場所に残す。
        case item(Item, isVisible: Bool)
        case separator
        /// 区切り線と同じくまとまりを分け、これより下のまとまりの項目をメニューで横に並べる。
        case rowSeparator
        /// これより下の項目は「その他」のサブメニューに入る。並びに1つだけある。
        case more
    }

    /// 区切り線で分けたメニューの1つのまとまり。
    public struct Group: Equatable, Sendable {
        public var items: [Item]
        /// 横並びの区切り線で始まったまとまりなら、項目を横に並べる。
        public var isRow: Bool

        public init(_ items: [Item], isRow: Bool = false) {
            self.items = items
            self.isRow = isRow
        }
    }

    /// メニューに出す項目を、区切り線で分けたまとまりにしたもの。空のまとまりは含めない。
    public struct Groups: Equatable, Sendable {
        public var main: [Group]
        /// 「その他」のサブメニューの中身。空なら「その他」を出さない。
        public var more: [Group]
    }

    public private(set) var elements: [Element]

    /// 既定の並びを書くためのもの。項目と「その他」がちょうど1つずつあるかは確かめない。
    /// 保存した値から作るときは`init(tokens:)`を使う。
    public init(defaultElements elements: [Element]) {
        self.elements = elements
    }

    /// 並べ替えや表示の切り替えのあとの並び。足りない項目と「その他」は、保存した並びを読んだときと同じ決まりで差し込む。
    public init(elements: [Element]) {
        self.elements = Self.completing(elements)
    }

    public var groups: Groups {
        var groups = Groups(main: [], more: [])
        var current: [Item] = []
        var isRow = false
        var inMore = false
        func close(startingRow: Bool) {
            if !current.isEmpty {
                let group = Group(current, isRow: isRow)
                if inMore { groups.more.append(group) } else { groups.main.append(group) }
            }
            current = []
            isRow = startingRow
        }
        for element in elements {
            switch element {
            case .item(let item, let isVisible):
                if isVisible { current.append(item) }
            case .separator:
                close(startingRow: false)
            case .rowSeparator:
                close(startingRow: true)
            case .more:
                close(startingRow: false)
                inMore = true
            }
        }
        close(startingRow: false)
        return groups
    }

    // MARK: - 保存

    /// 設定に保存する形。項目は`item:<rawValue>`か非表示の`hidden:<rawValue>`、区切り線は`separator`、横並びの区切り線は`row`、「その他」は`more`。
    public var tokens: [String] {
        elements.map { element in
            switch element {
            case .item(let item, let isVisible): "\(isVisible ? "item" : "hidden"):\(item.rawValue)"
            case .separator: "separator"
            case .rowSeparator: "row"
            case .more: "more"
            }
        }
    }

    /// 保存した並びを読む。知らない項目（なくなった項目）は捨て、まだ知らない新しい項目は既定の位置に差し込む。
    public init(tokens: [String]) {
        self.init(elements: tokens.compactMap(Self.element(from:)))
    }

    private static func element(from token: String) -> Element? {
        switch token {
        case "separator": return .separator
        case "row": return .rowSeparator
        case "more": return .more
        default:
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let item = Item(rawValue: parts[1]) else { return nil }
            switch parts[0] {
            case "item": return .item(item, isVisible: true)
            case "hidden": return .item(item, isVisible: false)
            default: return nil
            }
        }
    }

    // MARK: - 足りないものを差し込む

    /// 項目と「その他」の目印。差し込む位置を決めるときに、区切り線を数えないために使う。
    private enum Key: Hashable {
        case item(Item)
        case more
    }

    private static func key(of element: Element) -> Key? {
        switch element {
        case .item(let item, _): .item(item)
        case .more: .more
        case .separator, .rowSeparator: nil
        }
    }

    /// 重なった項目と「その他」は先に出たほうを残す。足りない項目と「その他」は、既定の並びで直前にあるもの（区切り線は数えない）の後ろに差し込み、表示は既定に従う。
    private static func completing(_ elements: [Element]) -> [Element] {
        var seen: Set<Key> = []
        var result = elements.filter { element in
            guard let key = key(of: element) else { return true }
            return seen.insert(key).inserted
        }
        var previous: Key?
        for element in Item.defaultLayout.elements {
            guard let key = key(of: element) else { continue }
            defer { previous = key }
            guard !seen.contains(key) else { continue }
            let index = previous.flatMap { anchor in result.firstIndex { Self.key(of: $0) == anchor } }.map { $0 + 1 } ?? 0
            result.insert(element, at: index)
            seen.insert(key)
        }
        return result
    }
}

/// 投稿のメニューの項目。通知のメニューも、対象の投稿のこのメニューで組む。
public enum StatusMenuItem: String, MenuItemKind {
    case reply
    case favourite
    case reblog
    case bookmark
    /// 投稿の会話をミュートする。自分の投稿、通知、自分へのメンションを含む投稿でだけ出る。
    case muteConversation
    /// 自分の投稿をプロフィールに固定する。固定できる自分の投稿でだけ出る。
    case pin
    /// 公開範囲を選んでブーストするサブメニュー。ブーストしていない、公開かひかえめな公開の投稿でだけ出る。
    case reblogWithVisibility
    case copyLink
    /// 本文をプレーンテキストにしてコピーする。本文のある投稿でだけ出る。
    case copyText
    case share
    /// 開く場所の設定に従って開く。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。
    case openInAppSafari
    /// 投稿の編集履歴を開く。編集された投稿でだけ出る。
    case editHistory
    /// 自分の投稿を投稿欄で編集する。自分の投稿でだけ出る。
    case edit
    /// 自分の投稿を削除する。自分の投稿でだけ出る。
    case delete
    /// 通知を削除する。通知でだけ出る。
    case dismissNotification
    /// 一覧で添付ファイルを覆う。添付ファイルがあり、覆っていない投稿でだけ出る。開くときは覆いをタップする。
    case hideMedia
    /// 本文をプレーンテキストにして、システムの翻訳シートで訳す。本文のある投稿でだけ出る。MastodonのAPIで訳す翻訳とは別の項目。
    case systemTranslate
    /// 通知した人のユーザーのメニュー。通知でだけ出る。
    case notifyingUser
    /// 投稿した人のユーザーのメニュー。ブーストなら元の投稿を書いた人。
    case author
    /// ブーストした人のユーザーのメニュー。ブーストでだけ出る。
    case booster
    /// メンションされた人ごとのユーザーのメニュー。
    case mentionedUsers

    /// 設定を足す前のメニューと同じ並び。足す前になかったメンションされたユーザーは隠しておく。
    /// ただし、返信・お気に入り・ブーストはよく使い、アイコンだけでも見分けられるので、横に並べる。横に並ぶのは3個までのため、同じまとまりにあった編集は次のまとまりの先頭へ移す。
    /// 設定を足したあとに増えた項目（メディアを隠す、テキストのコピー、翻訳、編集履歴、編集、削除、ブックマーク、会話のミュート、固定、公開範囲を選んでブースト、通知の削除）は、足したことに気づけるよう表示しておく。
    /// 削除と通知の削除は、誤って押さないよう「その他」に入れる。開く場所を選んで開く2つは、開く場所の設定と重なるため隠しておく。
    public static let defaultLayout = MenuLayout<StatusMenuItem>(defaultElements: [
        .rowSeparator,
        .item(.reply, isVisible: true),
        .item(.favourite, isVisible: true),
        .item(.reblog, isVisible: true),
        .separator,
        .item(.edit, isVisible: true),
        .item(.bookmark, isVisible: true),
        .item(.muteConversation, isVisible: true),
        .item(.pin, isVisible: true),
        .item(.reblogWithVisibility, isVisible: true),
        .item(.copyLink, isVisible: true),
        .item(.copyText, isVisible: true),
        .item(.share, isVisible: true),
        .item(.openInBrowser, isVisible: true),
        .item(.openInDefaultBrowser, isVisible: false),
        .item(.openInAppSafari, isVisible: false),
        .item(.editHistory, isVisible: true),
        .item(.hideMedia, isVisible: true),
        .item(.systemTranslate, isVisible: true),
        .separator,
        .item(.notifyingUser, isVisible: true),
        .item(.author, isVisible: true),
        .item(.booster, isVisible: true),
        .item(.mentionedUsers, isVisible: false),
        .more,
        .item(.dismissNotification, isVisible: true),
        .item(.delete, isVisible: true),
    ])
}

/// ユーザーのメニューの項目。投稿のメニューの中で、ユーザーごとのサブメニューとして出る。本文のメンションを長押ししたときも、このメニューを出す。
public enum UserMenuItem: String, MenuItemKind {
    case profile
    /// プロフィールのページのURLをコピーする。
    case copyLink
    /// プロフィールのページのURLを共有する。
    case share

    public static let defaultLayout = MenuLayout<UserMenuItem>(defaultElements: [
        .item(.profile, isVisible: true),
        .item(.copyLink, isVisible: true),
        .item(.share, isVisible: true),
        .more,
    ])
}

/// 本文のURLのリンクを長押ししたときのメニューの項目。開く場所を選んで開く2つは、開く場所の設定と重なるため隠しておく。
public enum LinkMenuItem: String, MenuItemKind {
    /// タップしたときと同じく、開く場所の設定に従って開く。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。httpとhttps以外のリンクでは押せない。
    case openInAppSafari
    case copyLink
    case share

    public static let defaultLayout = MenuLayout<LinkMenuItem>(defaultElements: [
        .item(.openInBrowser, isVisible: true),
        .item(.openInDefaultBrowser, isVisible: false),
        .item(.openInAppSafari, isVisible: false),
        .item(.copyLink, isVisible: true),
        .item(.share, isVisible: true),
        .more,
    ])
}

/// 本文のハッシュタグを長押ししたときのメニューの項目。アプリにはハッシュタグを開く画面がまだないため、開く項目はサーバーのハッシュタグのページをブラウザで開くものだけ。
public enum HashtagMenuItem: String, MenuItemKind {
    /// 開く場所の設定に従って開く。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。
    case openInAppSafari
    case copyLink
    case share

    public static let defaultLayout = MenuLayout<HashtagMenuItem>(defaultElements: [
        .item(.openInBrowser, isVisible: true),
        .item(.openInDefaultBrowser, isVisible: false),
        .item(.openInAppSafari, isVisible: false),
        .item(.copyLink, isVisible: true),
        .item(.share, isVisible: true),
        .more,
    ])
}
