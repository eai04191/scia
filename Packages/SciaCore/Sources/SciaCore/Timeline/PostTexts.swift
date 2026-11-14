import Foundation

/// 投稿と通知の行に出す文言。どのUIも同じ文言で出すため、行を描く側では書かない。
/// 通知の文は`NotificationKindAppearance`、投票の票数と期限は`PollDisplay.summary`、一覧の空と終わりの文は`TimelineTexts`にある。
public enum PostTexts {
    /// 固定された投稿の行の上に出すラベル。プロフィールの固定された投稿の棚の見出しにも使う。
    public static let pinned = "固定された投稿"

    /// ブーストした人の行の読み上げ。
    public static func boosted(by name: String) -> String {
        "\(name)がブースト"
    }

    /// 長い本文を切ったときに、末尾に出すボタン。
    public static let readMore = "続きを読む"

    /// 注意書きの読み上げで、注意書きの文の前に読む語。
    public static let contentWarningLabel = "注意書き"

    /// 注意書きのボックスの開閉のボタン。
    public static func contentWarningToggle(isCollapsed: Bool) -> String {
        isCollapsed ? "本文を表示" : "本文を隠す"
    }

    /// フィルターの警告のボックスを開くボタン。本文だけでなく添付ファイルやリンクカードも隠しているため、本文に限らない言い方にする。
    public static let filterWarningToggle = "投稿を表示"

    /// フィルターの警告と、フィルターでぼかした添付ファイルで、フィルターの名前の前に出す語。
    public static let filterWarningPrefix = "フィルター: "

    /// フィルターの警告に並べる、一致したフィルターの名前。
    public static func filterNames(_ titles: [String]) -> String {
        titles.joined(separator: "、")
    }

    /// 自分の投稿が、自分のフィルターに一致していることを示す1行。
    public static func ownFilterNote(titles: [String]) -> String {
        "フィルター" + titles.map { "“\($0)”" }.joined() + "に一致"
    }

    /// ぼかした添付ファイルの、理由の下に出す文言。
    public static let mediaCoverHint = "タップして表示"

    /// ぼかした添付ファイルの読み上げ。
    public static func mediaCoverAccessibilityLabel(_ cover: MediaCover?) -> String {
        "\(MediaCover.title(of: cover))、\(mediaCoverHint)"
    }

    /// まとめた通知で、最初の人の名前に続けて出す、ほかの人の数。`count`は最初の人を除いた数。
    public static func otherAccounts(count: Int) -> String {
        "ほか\(count.formatted())人"
    }

    /// 引用元の囲みの中で、引用元に投票があることを示す1行。
    public static let quotedPollNote = "投票"
    /// 引用元の囲みの中で、引用元がさらに引用していることを示す、押せる1行。
    public static let nestedQuoteNote = "引用した投稿があります"
    /// お気に入りやブーストの通知で再掲する投稿が、引用のある投稿であることを示す1行。
    public static let quoteNote = "引用した投稿"
    /// ブロックかミュートしている人の引用元を、押して開けることを示す文言。理由の下に出す。
    public static let revealQuote = "引用元を表示"
    /// 引用元がフィルターの「隠す」に一致したときに、囲みの代わりに出す1行。
    public static let quoteFiltered = "フィルターで隠しました"

    /// 投票のボタンと、選択肢のない投票に出す文言。
    public enum Poll {
        public static let vote = "投票"
        public static let reveal = "結果を見る"
        public static let returnToVoting = "投票に戻る"
        public static let refresh = "更新"
        public static let empty = "選択肢がありません"
        /// 自分が票を入れた選択肢の読み上げ。
        public static let ownVote = "投票済み"
    }
}

extension ReplyLabel {
    /// 返信のラベルの文言。
    public var title: String {
        switch self {
        case .continuation: "続き"
        case .toMe: "自分への返信"
        case .toAccount(let acct): "@\(acct)への返信"
        case .unknownAccount: "返信"
        }
    }
}

extension QuoteDisplay.Reason {
    /// 引用元を出せない理由の文言。
    public var title: String {
        switch self {
        case .pending: "承認待ちの引用です"
        case .withdrawn: "引用元の投稿者が引用を取り消しました"
        case .deleted: "引用元の投稿は削除されました"
        case .unauthorized: "引用元の投稿を表示できません"
        case .blockedAccount: "ブロックしている人の投稿です"
        case .blockedDomain: "ブロックしているドメインの人の投稿です"
        case .mutedAccount: "ミュートしている人の投稿です"
        }
    }
}

extension MediaCover {
    /// ぼかしている理由。使う人が隠した投稿に「閲覧注意」と出すと、投稿者が付けたように読めるため、文言を分ける。
    /// フィルターでぼかした投稿は、どのフィルターに一致したかを出す。
    public static func title(of cover: MediaCover?) -> String {
        switch cover {
        case .hidden: "非表示"
        case .filtered(let titles): PostTexts.filterWarningPrefix + PostTexts.filterNames(titles)
        case .sensitive, nil: "閲覧注意"
        }
    }
}
