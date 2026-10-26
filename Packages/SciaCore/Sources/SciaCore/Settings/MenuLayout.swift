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
    /// 投稿欄で投稿を引用して書き始める。引用に対応したサーバーでだけ出て、引用できない投稿では押せない。
    case quote
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
    /// 投稿をお気に入りした人の一覧を開く。お気に入りされた投稿でだけ出る。
    case favouritedBy
    /// 投稿をブーストした人の一覧を開く。ブーストされた投稿でだけ出る。
    case rebloggedBy
    /// 自分の投稿を投稿欄で編集する。自分の投稿でだけ出る。
    case edit
    /// 自分の投稿を削除する。自分の投稿でだけ出る。
    case delete
    /// 通知を削除する。通知でだけ出る。
    case dismissNotification
    /// 一覧で添付ファイルをぼかす。添付ファイルがあり、ぼかしていない投稿でだけ出る。開くときはぼかしをタップする。
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

    /// 既定は、よく押す項目だけをメニューに並べ、上ほどよく押すものを置いて、何のための操作かでまとまりを分ける。
    /// どの項目も設定を開かずに選べるよう、たまにしか使わない項目は隠さずに「その他」へ入れる。隠すのは、ほかの設定で代わりがきく項目と、メニューを長くしやすい項目だけにする。
    /// - 返信・お気に入り・ブースト: いちばんよく使い、アイコンだけでも見分けられるので、横に並べる
    /// - 反応のつづき: 編集（自分の投稿でだけ出る。自分の投稿では返信などより先に使う）、ブックマーク、引用。公開範囲を選んでブーストは、ブーストの公開範囲の設定で代わりがきくため隠し、出したときにブーストの近くに来るようここに置く
    /// - 持ち出す: リンクとテキストのコピー、共有、ブラウザで開く。開く場所を選んで開く2つは、開く場所の設定と重なるため隠す
    /// - 読む: 翻訳
    /// - 関係するユーザーとハッシュタグ: メンションされたユーザーは、何人もいるとメニューが長くなるため隠す。ハッシュタグは、ある投稿でしか出ないので、「その他」に入れずに出す
    /// - 「その他」: たまにしか使わない編集履歴、お気に入りした人、ブーストした人、メディアを隠す、カスタム絵文字、会話のミュート、固定と、取り消せない通知の削除、投稿の削除
    public static let defaultLayout = MenuLayout<StatusMenuItem>(defaultElements: [
        .rowSeparator,
        .item(.reply, isVisible: true),
        .item(.favourite, isVisible: true),
        .item(.reblog, isVisible: true),
        .separator,
        .item(.edit, isVisible: true),
        .item(.bookmark, isVisible: true),
        .item(.quote, isVisible: true),
        .item(.reblogWithVisibility, isVisible: false),
        .separator,
        .item(.copyLink, isVisible: true),
        .item(.copyText, isVisible: true),
        .item(.share, isVisible: true),
        .item(.openInBrowser, isVisible: true),
        .item(.openInDefaultBrowser, isVisible: false),
        .item(.openInAppSafari, isVisible: false),
        .separator,
        .item(.systemTranslate, isVisible: true),
        .separator,
        .item(.notifyingUser, isVisible: true),
        .item(.author, isVisible: true),
        .item(.booster, isVisible: true),
        .item(.mentionedUsers, isVisible: false),
        .item(.hashtags, isVisible: true),
        .more,
        .item(.editHistory, isVisible: true),
        .item(.favouritedBy, isVisible: true),
        .item(.rebloggedBy, isVisible: true),
        .item(.hideMedia, isVisible: true),
        .item(.customEmojis, isVisible: true),
        .separator,
        .item(.muteConversation, isVisible: true),
        .item(.pin, isVisible: true),
        .separator,
        .item(.dismissNotification, isVisible: true),
        .item(.delete, isVisible: true),
    ])
}

/// ユーザーのメニューの項目。投稿のメニューの中で、ユーザーごとのサブメニューとして出る。本文のメンションを長押ししたときと、プロフィール画面でも、このメニューを出す。
/// 開く場所を選んで開く2つは、開く場所の設定と重なるため隠しておく。
public enum UserMenuItem: String, MenuItemKind {
    case profile
    /// 投稿欄で、カーソルの位置に`@acct`を入れる。
    case mention
    /// サーバー名を付けた`@username@domain`の形でコピーする。
    case copyHandle
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
    /// フォローしている相手のブーストを、ホームに流すかを切り替える。
    case showReblogs
    /// フォローしている相手が投稿したら通知するかを切り替える。
    case notify
    /// ミュートしていなければ、期間を選んでミュートする。ミュート中なら解除する。
    case mute
    /// ブロックしていなければブロックし、ブロック中なら解除する。
    case block
    /// 通報のシートを開く。
    case report

    public static let defaultLayout = MenuLayout<UserMenuItem>(defaultElements: [
        .item(.profile, isVisible: true),
        .item(.mention, isVisible: true),
        .separator,
        .item(.follow, isVisible: true),
        .separator,
        .item(.copyHandle, isVisible: true),
        .item(.copyLink, isVisible: true),
        .item(.share, isVisible: true),
        .item(.openInBrowser, isVisible: true),
        .item(.openInDefaultBrowser, isVisible: false),
        .item(.openInAppSafari, isVisible: false),
        .more,
        .item(.showReblogs, isVisible: true),
        .item(.notify, isVisible: true),
        .separator,
        .item(.mute, isVisible: true),
        .item(.block, isVisible: true),
        .item(.report, isVisible: true),
    ])

    /// 相手との関係で中身が変わる項目。通報は関係で変わらず、自分に出さないかはIDで決まるため含めない。
    public var dependsOnRelationship: Bool {
        switch self {
        case .follow, .showReblogs, .notify, .mute, .block: true
        case .profile, .mention, .copyHandle, .copyLink, .share, .openInBrowser, .openInDefaultBrowser, .openInAppSafari, .report: false
        }
    }
}

extension MenuLayout<UserMenuItem>.Groups {
    /// 出している項目に、相手との関係で中身が変わるものがある。ないなら、メニューを開いても関係を読まない。
    public var needsRelationship: Bool {
        (main + more).flatMap(\.items).contains(where: \.dependsOnRelationship)
    }
}

/// 本文のURLのリンクを長押ししたときのメニューの項目。開く場所を選んで開く2つは、開く場所の設定と重なるため隠しておく。
public enum LinkMenuItem: String, MenuItemKind {
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

    public static let defaultLayout = MenuLayout<LinkMenuItem>(defaultElements: [
        .item(.openInBrowser, isVisible: true),
        .item(.openAsProfile, isVisible: true),
        .item(.openInDefaultBrowser, isVisible: false),
        .item(.openInAppSafari, isVisible: false),
        .item(.copyLink, isVisible: true),
        .item(.share, isVisible: true),
        .more,
    ])
}

/// 本文のハッシュタグを長押ししたときのメニューの項目。
public enum HashtagMenuItem: String, MenuItemKind {
    /// ハッシュタグのタイムラインを開く。ハッシュタグをタップしたときと同じ。
    case timeline
    /// 投稿の本文なら投稿した人、プロフィールならその人の、このハッシュタグの付いた投稿を開く。
    case accountStatuses
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

    public static let defaultLayout = MenuLayout<HashtagMenuItem>(defaultElements: [
        .item(.timeline, isVisible: true),
        .item(.accountStatuses, isVisible: true),
        .separator,
        .item(.mute, isVisible: true),
        .separator,
        .item(.openInBrowser, isVisible: true),
        .item(.openInDefaultBrowser, isVisible: false),
        .item(.openInAppSafari, isVisible: false),
        .item(.copyLink, isVisible: true),
        .item(.share, isVisible: true),
        .more,
    ])
}

/// 一覧のサムネイル、リンクカードの画像、プロフィールの画像を長押ししたときと、ビューアのメニューの項目。決まりはdocs/menus.mdの「メディアのメニュー」にある。
public enum MediaMenuItem: String, MenuItemKind {
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

    /// - 開く・共有・写真に保存
    /// - 読む: 代替テキスト、画像の文字を翻訳
    /// - 持ち出す: リンクのコピー、ブラウザで開く。開く場所を選んで開く2つは、ほかのメニューと同じく隠す
    /// - 投稿
    /// - 「その他」: メディアの情報
    public static let defaultLayout = MenuLayout<MediaMenuItem>(defaultElements: [
        .item(.open, isVisible: true),
        .item(.share, isVisible: true),
        .item(.saveToPhotos, isVisible: true),
        .separator,
        .item(.altText, isVisible: true),
        .item(.translateText, isVisible: true),
        .separator,
        .item(.copyLink, isVisible: true),
        .item(.openInBrowser, isVisible: true),
        .item(.openInDefaultBrowser, isVisible: false),
        .item(.openInAppSafari, isVisible: false),
        .separator,
        .item(.status, isVisible: true),
        .more,
        .item(.info, isVisible: true),
    ])
}
