/// 一覧ごとに変わる文言。
public struct TimelineTexts: Sendable {
    /// 違和感レポートの状態ダンプに使う名前。
    public let dumpName: String
    public let title: String
    /// 題の下に添える文字。ストリーミングの切断を知らせるときは、その前に並べる。
    public var subtitle: String?
    /// 1件もないとき。
    public let empty: String
    /// これより古いものがないとき。
    public let reachedEnd: String
    /// サーバーから届いたが、読めなかった要素の行。
    public let unreadable: String

    public init(dumpName: String, title: String, subtitle: String? = nil, empty: String, reachedEnd: String, unreadable: String) {
        self.dumpName = dumpName
        self.title = title
        self.subtitle = subtitle
        self.empty = empty
        self.reachedEnd = reachedEnd
        self.unreadable = unreadable
    }

    public static let home = TimelineTexts(dumpName: "timeline", title: "ホーム", empty: "投稿がありません", reachedEnd: "これより前の投稿はありません", unreadable: "表示できない投稿")
    public static let local = TimelineTexts(dumpName: "local", title: "ローカル", empty: "投稿がありません", reachedEnd: "これより前の投稿はありません", unreadable: "表示できない投稿")
    public static let federated = TimelineTexts(dumpName: "federated", title: "連合", empty: "投稿がありません", reachedEnd: "これより前の投稿はありません", unreadable: "表示できない投稿")
    public static let bookmarks = TimelineTexts(dumpName: "bookmarks", title: "ブックマーク", empty: "ブックマークした投稿はありません", reachedEnd: "これより前にブックマークした投稿はありません", unreadable: "表示できない投稿")
    public static let favourites = TimelineTexts(dumpName: "favourites", title: "お気に入り", empty: "お気に入りした投稿はありません", reachedEnd: "これより前にお気に入りした投稿はありません", unreadable: "表示できない投稿")
    public static func list(title: String) -> TimelineTexts {
        TimelineTexts(dumpName: "list", title: title, empty: "投稿がありません", reachedEnd: "これより前の投稿はありません", unreadable: "表示できない投稿")
    }
    public static func hashtag(name: String) -> TimelineTexts {
        TimelineTexts(dumpName: "hashtag", title: "#\(name)", empty: "投稿がありません", reachedEnd: "これより前の投稿はありません", unreadable: "表示できない投稿")
    }
    /// `acct`のユーザーの、ハッシュタグの付いた投稿。題に入り切るよう、ハンドルは題の下に出す。
    public static func accountHashtag(name: String, acct: String) -> TimelineTexts {
        TimelineTexts(dumpName: "accountHashtag", title: "#\(name)", subtitle: "@\(acct)", empty: "投稿がありません", reachedEnd: "これより前の投稿はありません", unreadable: "表示できない投稿")
    }
    public static let notificationRequests = TimelineTexts(dumpName: "notificationRequests", title: "保留中の通知", empty: "保留中の通知はありません", reachedEnd: "", unreadable: "表示できないアカウント")
    /// 保留中の通知の1人分の、その人からの通知。
    public static func accountNotifications(name: String) -> TimelineTexts {
        TimelineTexts(dumpName: "accountNotifications", title: "\(name)からの通知", empty: "通知はありません", reachedEnd: "これより前の通知はありません", unreadable: "表示できない通知")
    }
    /// 検索欄に打っている途中の候補と最近の検索。状態ダンプで結果の一覧と見分けられるよう、名前を分ける。行がないときは一覧を出さないので、空の文は使わない。
    public static let searchSuggestions = TimelineTexts(dumpName: "searchSuggestions", title: "検索", empty: "", reachedEnd: "", unreadable: "表示できない投稿")
    /// 検索の結果。1つの種類だけの一覧では、題に種類を、題の下に探した語を出す。
    public static func search(_ scope: SearchModel.Scope, query: String) -> TimelineTexts {
        switch scope {
        case .all:
            // 0件の種類は見出しごと出さないため、投稿が0件のときに、全文検索のないサーバーでは投稿を探せないことをここで伝える。
            TimelineTexts(dumpName: "search", title: "検索", empty: "見つかりませんでした。投稿は、全文検索に対応したサーバーでだけ探せます", reachedEnd: "", unreadable: "表示できない投稿")
        case .only(let category):
            TimelineTexts(dumpName: "search", title: category.title, subtitle: query, empty: "見つかりませんでした", reachedEnd: "", unreadable: "表示できない投稿")
        }
    }
    public static let notifications = TimelineTexts(dumpName: "notifications", title: "通知", empty: "通知はありません", reachedEnd: "これより前の通知はありません", unreadable: "表示できない通知")
    public static let profile = TimelineTexts(dumpName: "profile", title: "", empty: "投稿がありません", reachedEnd: "これより前の投稿はありません", unreadable: "表示できない投稿")
    public static let thread = TimelineTexts(dumpName: "thread", title: "スレッド", empty: "投稿がありません", reachedEnd: "", unreadable: "表示できない投稿")
    public static func accountList(_ kind: AccountListKind) -> TimelineTexts {
        let (title, empty) = switch kind {
        case .favouritedBy: ("お気に入りした人", "お気に入りした人はいません")
        case .rebloggedBy: ("ブーストした人", "ブーストした人はいません")
        case .followers: ("フォロワー", "フォロワーはいません")
        case .following: ("フォロー", "フォローしている人はいません")
        case .listMembers: ("メンバー", "メンバーはいません")
        }
        return TimelineTexts(dumpName: "accountList", title: title, empty: empty, reachedEnd: "", unreadable: "表示できないアカウント")
    }
}
