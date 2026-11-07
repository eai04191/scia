/// メニューの項目の種類。対象（投稿、ユーザー）ごとに1つ作る。
/// `rawValue`は設定に保存するため、一度使った値は変えない。
public protocol MenuItemKind: RawRepresentable<String>, CaseIterable, Hashable, Sendable {
    /// 既定の並び。項目を足すときは、ここにも足す（`BundledMenuDefaults`ならmenu-defaults.jsonに足す）。足した項目を保存済みの並びのどこに入れるかも、この並びで決まる。
    static var defaultLayout: MenuLayout<Self> { get }
    /// このメニューの並びの設定の画面を開く項目。ほかに出す項目がないときは、この項目も出さない。決まりはdocs/menus.mdの「並びの設定」にある。
    static var customizeItem: Self? { get }
}

extension MenuItemKind {
    public static var customizeItem: Self? { nil }
}

/// メニューの並び。項目、区切り線、「その他」の境目を1本に並べる。決まりはdocs/menus.mdにある。
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

        /// 1つのまとまりだけの並び。アクションバーのボタンを長押しして出すメニューのように、決まった項目だけを、メニューと同じ組み方で組むために使う。
        public static func items(_ items: [Item]) -> Groups {
            Groups(main: [Group(items)], more: [])
        }

        /// 1つの項目だけの並び。タップや長押しに割り当てた項目を、メニューと同じ組み方で組むために使う。
        public static func single(_ item: Item) -> Groups {
            Groups(main: [Group([item])], more: [])
        }

        /// `items`を除いた並び。項目がなくなったまとまりは含めない。出す場所で意味のない項目（ハッシュタグのタイムラインの「すべての投稿」など）を除くのに使う。
        /// 並び（`MenuLayout`）から除くと、足りない項目として既定の位置に差し込み直されるため、まとまりにしてから除く。
        /// 除いたせいで「その他」の外が空になったら、「その他」の中身をそのまま並べる。「その他」1つだけのメニューを開かせないため。
        /// 使う人が「その他」の外をみな隠した並びは、除く前から外が空なので、そのまま「その他」に残す。
        public func excluding(_ items: Set<Item>) -> Groups {
            func filtered(_ groups: [Group]) -> [Group] {
                groups.compactMap { group in
                    let kept = group.items.filter { !items.contains($0) }
                    return kept.isEmpty ? nil : Group(kept, isRow: group.isRow)
                }
            }
            let keptMain = filtered(main)
            let keptMore = filtered(more)
            if keptMain.isEmpty, !main.isEmpty {
                return Groups(main: keptMore, more: [])
            }
            return Groups(main: keptMain, more: keptMore)
        }
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
        groups(revealing: [])
    }

    /// `revealing`の項目は、隠していても並びの位置に出す。
    private func groups(revealing: Set<Item>) -> Groups {
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
                if isVisible || revealing.contains(item) { current.append(item) }
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

    /// ほかの対象のメニューの中に、この対象のサブメニューで出すときの並び。タップと長押しに割り当てた項目は、隠していても並びの位置に出す。
    /// 1段目のメニューではタップや長押しで行えるので隠すが、メニューの中で対象を選んだときは、閉じて押し直させないため。決まりはdocs/menus.mdの「並びの設定」にある。
    public func submenuGroups(actions: ObjectActions<Item>) -> Groups {
        groups(revealing: actions.assignedItems)
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

    static func element(from token: String) -> Element? {
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
    /// 足りない項目は、既定の並びですぐ前か後ろにある区切り線も一緒に入れる。決まりはdocs/menus.mdの「あとから項目が増えたとき」にある。
    private static func completing(_ elements: [Element]) -> [Element] {
        var seen: Set<Key> = []
        var result = elements.filter { element in
            guard let key = key(of: element) else { return true }
            return seen.insert(key).inserted
        }
        let defaults = Item.defaultLayout.elements
        var previous: Key?
        for (offset, element) in defaults.enumerated() {
            guard let key = key(of: element) else { continue }
            defer { previous = key }
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let index = previous.flatMap { anchor in result.firstIndex { Self.key(of: $0) == anchor } }.map { $0 + 1 } ?? 0
            guard case .item = element else {
                result.insert(element, at: index)
                continue
            }
            let before = offset > 0 ? defaults[offset - 1] : nil
            let after = offset + 1 < defaults.count ? defaults[offset + 1] : nil
            insert(element, at: index, separatorBefore: before.flatMap(separator(_:)), separatorAfter: after.flatMap(separator(_:)), into: &result)
        }
        return result
    }

    /// 項目を`index`に入れ、既定の並びでその側にある区切り線を足す。並びの端と「その他」の境目に接する側と、すでに区切り線がある側には足さない。
    /// 前に区切り線が要り、入れる位置のすぐ後ろがもう区切り線なら、並びの先頭や「その他」の境目でも、その区切り線の後ろに入れる。区切り線を2本並べず、既定で横並びの区切り線の下にある項目を、その下のまとまりに戻すため。
    private static func insert(_ element: Element, at index: Int, separatorBefore: Element?, separatorAfter: Element?, into result: inout [Element]) {
        var index = index
        if separatorBefore != nil, index < result.count, separator(result[index]) != nil {
            index += 1
        } else if let separatorBefore, index > 0, result[index - 1] != .more {
            result.insert(separatorBefore, at: index)
            index += 1
        }
        result.insert(element, at: index)
        let next = index + 1
        if let separatorAfter, next < result.count, result[next] != .more, separator(result[next]) == nil {
            result.insert(separatorAfter, at: next)
        }
    }

    /// 区切り線（横並びの区切り線も含む）ならそれを、ほかはnilを返す。
    private static func separator(_ element: Element) -> Element? {
        switch element {
        case .separator, .rowSeparator: element
        case .item, .more: nil
        }
    }
}

/// 投稿のメニューの項目。通知のメニューも、対象の投稿のこのメニューで組む。
public enum StatusMenuItem: String, BundledMenuDefaults {
    /// 投稿のスレッドを開く。投稿と通知のタップの既定。スレッドの中心の投稿と、投稿のない通知では出ない。
    case openThread
    case reply
    case favourite
    case reblog
    case bookmark
    /// 投稿欄で投稿を引用して書き始める。引用に対応したサーバーでだけ出て、引用できない投稿では押せない。
    case quote
    /// 絵文字のシートを開き、選んだ絵文字で投稿にリアクションする。絵文字のリアクションに対応したサーバーでだけ出る（docs/emoji-reaction.md）。
    case emojiReaction
    /// 投稿の会話をミュートする。自分の投稿、通知、自分へのメンションを含む投稿でだけ出る。
    case muteConversation
    /// 自分の投稿をプロフィールに固定する。固定できる自分の投稿でだけ出る。
    case pin
    /// 公開範囲を選んでブーストするサブメニュー。ブーストしていない、公開かひかえめな公開の投稿でだけ出る。
    case reblogWithVisibility
    /// ログインしているほかのアカウントとして投稿を操作するサブメニュー。ほかのアカウントでログインしているときだけ出る。決まりはdocs/other-accounts.mdにある。
    case otherAccounts
    case copyLink
    /// 本文をプレーンテキストにしてコピーする。本文のある投稿でだけ出る。
    case copyText
    /// 行の本文を、その場で文字を選べる状態にする。本文を表示している投稿でだけ出る。
    case selectText
    case share
    /// タイムラインで投稿を順番を付けて選び始める。選んだ投稿は、まとめてブーストや共有ができる。決まりはdocs/batch-actions.mdにある。
    case select
    /// 開く場所の設定に従って開く。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。
    case openInAppSafari
    /// 投稿の編集履歴を開く。編集された投稿でだけ出る。
    case editHistory
    /// 投稿をお気に入りした人のリストを開く。お気に入りされた投稿でだけ出る。
    case favouritedBy
    /// 投稿をブーストした人のリストを開く。ブーストされた投稿でだけ出る。
    case rebloggedBy
    /// 自分の投稿を投稿欄で編集する。自分の投稿でだけ出る。
    case edit
    /// 自分の投稿を削除する。自分の投稿でだけ出る。
    case delete
    /// 自分の投稿を投稿欄に戻して書き直し、送るときに元の投稿を削除する。自分の投稿でだけ出る。
    case redraft
    /// 通知を削除する。通知でだけ出る。
    case dismissNotification
    /// タイムラインで添付ファイルをぼかす。添付ファイルがあり、ぼかしていない投稿でだけ出る。開くときはぼかしをタップする。
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
    /// 投稿の行に描くカスタム絵文字ごとの、絵文字の画像のメディアのメニュー。カスタム絵文字のある投稿でだけ出る。
    case customEmojis
    /// 投稿のハッシュタグごとの、ハッシュタグのメニュー。ハッシュタグのある投稿でだけ出る。
    case hashtags
    /// 投稿をサーバーから読み直し、APIの応答のJSONを出す。サーバーが付けた値（言語など）を確かめるためのもの。
    case apiResponse

    /// このメニューの並びの設定の画面を開く。決まりはdocs/menus.mdの「並びの設定」にある。
    case customize
    public static var customizeItem: Self? { .customize }

    public static let defaultsKey = "status"
    public static let defaultLayout = MenuLayout<StatusMenuItem>.bundledDefault()
}

/// ユーザーのメニューの項目。投稿のメニューの中で、ユーザーごとのサブメニューとして出る。本文のメンションを長押ししたときと、プロフィール画面でも、このメニューを出す。
public enum UserMenuItem: String, BundledMenuDefaults {
    case profile
    /// 投稿欄で、カーソルの位置に`@acct`を入れる。
    case mention
    /// サーバー名を付けた`@username@domain`の形でコピーする。
    case copyHandle
    /// `@`を付けない`username`をコピーする。
    case copyUsername
    /// `domain`をコピーする。同じサーバーのユーザーでは、ログインしているサーバーの名前にする。
    case copyServer
    /// プロフィールのページのURLをコピーする。
    case copyLink
    /// プロフィールのページのURLを共有する。
    case share
    /// プロフィールのページを、開く場所の設定に従って開く。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。
    case openInAppSafari
    /// フォローしていなければフォローし、フォロー中なら外し、リクエスト中なら取り消す。以下の関係の項目は、相手との関係に合わせて出す。自分には出さない。
    case follow
    /// その人をどのリストに入れるかを選ぶシートを開く。Mastodonは自分をリストに入れられるので、自分にも出す。決まりはdocs/lists.mdの「リストに追加」にある。
    case addToList
    /// フォローしている相手のブーストを、ホームに流すかを切り替える。
    case showReblogs
    /// フォローしている相手が投稿したら通知するかを切り替える。
    case notify
    /// フォローしている相手を、自分のプロフィールで紹介する。紹介していれば外す。
    case endorse
    /// 相手のプロフィールに、自分にしか見えないメモを書くシートを開く。メモがあれば編集する。メモは関係と一緒に返る。
    case note
    /// ミュートしていなければ、期間を選んでミュートする。ミュート中なら解除する。
    case mute
    /// ブロックしていなければブロックし、ブロック中なら解除する。
    case block
    /// 通報のシートを開く。
    case report
    /// ログインしているほかのアカウントとしてその人を操作するサブメニュー。ほかのアカウントでログインしているときだけ出る。決まりはdocs/other-accounts.mdにある。
    case otherAccounts

    /// このメニューの並びの設定の画面を開く。決まりはdocs/menus.mdの「並びの設定」にある。
    case customize
    public static var customizeItem: Self? { .customize }

    public static let defaultsKey = "user"
    public static let defaultLayout = MenuLayout<UserMenuItem>.bundledDefault()

    /// コピーの項目。プロフィールのハンドルを押したときのメニューも、この順に並べる。
    public static let copyItems: [UserMenuItem] = [.copyHandle, .copyUsername, .copyServer, .copyLink]

    /// コピーの項目のうち、ハンドルの一部をコピーするもの。ほかの項目はnil。
    public var handlePart: UserHandlePart? {
        switch self {
        case .copyHandle: .handle
        case .copyUsername: .username
        case .copyServer: .server
        default: nil
        }
    }

    /// 相手との関係で中身が変わる項目。通報は関係で変わらず、自分に出さないかはIDで決まるため含めない。
    public var dependsOnRelationship: Bool {
        switch self {
        case .follow, .showReblogs, .notify, .endorse, .note, .mute, .block: true
        // 「別のアカウントで」の中の関係は、そのアカウントで読み直す（`UserMenuTree.refreshOtherAccounts(groups:)`）。
        case .profile, .mention, .copyHandle, .copyUsername, .copyServer, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .addToList, .report, .otherAccounts, .customize: false
        }
    }
}

extension MenuLayout<UserMenuItem>.Groups {
    /// 出している項目に、相手との関係で中身が変わるものがある。ないなら、メニューを開いても関係を読まない。
    public var needsRelationship: Bool {
        (main + more).flatMap(\.items).contains(where: \.dependsOnRelationship)
    }
}

/// 本文のURLのリンクを長押ししたときのメニューの項目。
public enum LinkMenuItem: String, BundledMenuDefaults {
    /// タップしたときと同じく、開く場所の設定に従って開く。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。httpとhttps以外のリンクでは押せない。
    case openInAppSafari
    /// リンク先をプロフィールとして探し、見つかればプロフィールを開く。
    /// `@`の付かないURL（Pixelfedなど）もあり、URLの形や本文のHTMLやリンクのカードからはプロフィールか見分けられないため、使う人に選んでもらう。
    /// 探すにはサーバーが相手のページを取りに行くので、選んだときだけ探す。
    case openAsProfile
    case copyLink
    case share

    /// このメニューの並びの設定の画面を開く。決まりはdocs/menus.mdの「並びの設定」にある。
    case customize
    public static var customizeItem: Self? { .customize }

    public static let defaultsKey = "link"
    public static let defaultLayout = MenuLayout<LinkMenuItem>.bundledDefault()
}

/// ほかのサービスの投稿（Xの投稿の囲みなど）を長押ししたときのメニューの項目。決まりはdocs/menus.mdの「メニューの単位」にある。
public enum ExternalPostMenuItem: String, BundledMenuDefaults {
    /// 元の投稿を、開く場所の設定に従って開く。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。
    case openInAppSafari
    case copyLink
    /// 本文をプレーンテキストにしてコピーする。本文のある投稿でだけ出る。
    case copyText
    case share
    /// 本文をプレーンテキストにして、システムの翻訳シートで訳す。本文のある投稿でだけ出る。
    case systemTranslate

    /// このメニューの並びの設定の画面を開く。決まりはdocs/menus.mdの「並びの設定」にある。
    case customize
    public static var customizeItem: Self? { .customize }

    public static let defaultsKey = "externalPost"
    public static let defaultLayout = MenuLayout<ExternalPostMenuItem>.bundledDefault()
}

/// プロフィールの表示名、自己紹介、補足情報の行を長押ししたときのメニューの項目。決まりはdocs/menus.mdの「プロフィールの文章のメニュー」にある。
public enum ProfileTextMenuItem: String, BundledMenuDefaults {
    /// 文章をプレーンテキストにしてコピーする。文字のある文章でだけ出る。
    case copyText
    /// 補足情報のラベルをプレーンテキストにしてコピーする。文字のあるラベルの補足情報の行でだけ出る。
    case copyLabel
    /// 文章をプレーンテキストにして、システムの翻訳シートで訳す。文字のある文章でだけ出る。
    case systemTranslate
    /// 文章に描いているカスタム絵文字ごとに、絵文字の画像のメディアのメニューを出す。絵文字のある文章でだけ出る。
    case customEmojis

    /// このメニューの並びの設定の画面を開く。決まりはdocs/menus.mdの「並びの設定」にある。
    case customize
    public static var customizeItem: Self? { .customize }

    public static let defaultsKey = "profileText"
    public static let defaultLayout = MenuLayout<ProfileTextMenuItem>.bundledDefault()
}

/// 本文のハッシュタグを長押ししたときのメニューの項目。
public enum HashtagMenuItem: String, BundledMenuDefaults {
    /// ハッシュタグのタイムラインを開く。ハッシュタグをタップしたときと同じ。
    case timeline
    /// 投稿の本文なら投稿した人、プロフィールならその人の、このハッシュタグの付いた投稿を開く。
    case accountStatuses
    /// フォローする。フォローしていれば外す。
    case follow
    /// このハッシュタグの付いた投稿を、サーバーのフィルターで隠す。ミュート中なら解除する。
    case mute
    /// 開く場所の設定に従って開く。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。
    case openInAppSafari
    case copyLink
    case share
    /// 自分のプロフィールの注目のハッシュタグに載せる。載せていれば外す。
    case feature

    /// このメニューの並びの設定の画面を開く。決まりはdocs/menus.mdの「並びの設定」にある。
    case customize
    public static var customizeItem: Self? { .customize }

    public static let defaultsKey = "hashtag"
    public static let defaultLayout = MenuLayout<HashtagMenuItem>.bundledDefault()
}

/// 投稿の絵文字のリアクションのボタンを長押ししたときのメニューの項目。決まりはdocs/emoji-reaction.mdの「リアクションのボタンのメニュー」にある。
public enum ReactionMenuItem: String, BundledMenuDefaults {
    /// その絵文字で付け外しする。ボタンをタップしたときと同じ。
    case toggle
    /// その絵文字でリアクションした人のリストを開く。
    case reactedBy
    /// カスタム絵文字の画像をビューアで開く。画像のあるカスタム絵文字でだけ出る。
    case open

    /// このメニューの並びの設定の画面を開く。決まりはdocs/menus.mdの「並びの設定」にある。
    case customize
    public static var customizeItem: Self? { .customize }

    public static let defaultsKey = "reaction"
    public static let defaultLayout = MenuLayout<ReactionMenuItem>.bundledDefault()
}

/// タイムラインのサムネイル、リンクカードの画像、プロフィールの画像を長押ししたときと、ビューアのメニューの項目。決まりはdocs/menus.mdの「メディアのメニュー」にある。
public enum MediaMenuItem: String, BundledMenuDefaults {
    /// ビューアで開く。ビューアでは出ない。
    case open
    /// ファイルを共有する。
    case share
    /// 写真に保存する。写真に入る画像、動画、GIFでだけ出る。
    case saveToPhotos
    /// 代替テキストの全文を見せる。代替テキストが付いているときだけ出る。
    case altText
    /// 画像から読み取った文字を、システムの翻訳シートで訳す。ビューアで文字を読み取れたときだけ出る。
    case translateText
    /// ファイルのURLをコピーする。
    case copyLink
    /// 開く場所の設定に従って、ファイルのURLを開く。
    case openInBrowser
    /// 開く場所の設定にかかわらず、既定のブラウザで開く。
    case openInDefaultBrowser
    /// 開く場所の設定にかかわらず、アプリ内のSafariで開く。
    case openInAppSafari
    /// メディアの投稿の、投稿のメニュー。ビューアとプロフィールの画像では出ない。
    case status
    /// 解像度や形式などを並べるサブメニュー。
    case info

    /// このメニューの並びの設定の画面を開く。決まりはdocs/menus.mdの「並びの設定」にある。
    case customize
    public static var customizeItem: Self? { .customize }

    public static let defaultsKey = "media"
    public static let defaultLayout = MenuLayout<MediaMenuItem>.bundledDefault()
}
