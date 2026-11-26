/// アカウントの画面一式（タブ、メニュー、操作の結果）に出す文言のうち、値の型に結び付かないもの。
/// どのUIも同じ文言で出すため、画面を組む側では書かない。
public enum SessionTexts {
    /// アカウントのボタン（左上）の読み上げ。
    public static let accountButton = "アカウント"
    /// アカウントのメニューの、サーバーのお知らせを開く項目。
    public static let announcements = "サーバーのお知らせ"

    /// アカウントのメニューの、サーバーのお知らせを開く項目に添える未読の数。
    public static func unreadAnnouncements(count: Int) -> String {
        "未読\(count)件"
    }

    /// 未読のお知らせがあるときの、アカウントのボタンのヒント。
    public static func unreadAnnouncementsHint(count: Int) -> String {
        "未読のお知らせが\(count)件あります。"
    }

    /// 通知のタブの、保留中の通知を開くボタンの読み上げ。
    /// - Parameter countText: 保留中の通知を送った人の数を、バッジと同じ書き方にしたもの。いなければnil。
    public static func pendingRequests(countText: String?) -> String {
        guard let countText else { return "保留中の通知" }
        return "保留中の通知、\(countText)人"
    }

    /// ステータスバーの通知のデモで流す文。
    public static let statusBarTickerDemo = "通知はここに流れます"

    /// リストの画面の、メンバーを足すボタン。
    public static let addListMember = "メンバーを追加"

    /// 予約できたことのチップ。
    /// - Parameter date: 予約した日時を短く書いたもの（`ScheduleDateText.shortTitle`）。
    public static func scheduled(at date: String) -> String {
        "\(date)に予約しました"
    }

    /// 予約できたことのチップのヒント。
    public static let scheduledHint = "予約投稿を表示します。"

    /// 予約を書き直した投稿を送れたが、元の予約を取り消せなかったときのアラート。
    public enum RewrittenSchedule {
        public static let cancelFailure = "元の予約を取り消せませんでした"
        /// 理由の前に添える文。
        public static let reasonLead = "書き直した投稿は送りましたが、元の予約が残っています。両方投稿されないよう、予約投稿の画面から取り消してください。"
        public static let openScheduled = "予約投稿を開く"
        public static let close = "閉じる"
    }

    /// 引用できる人を変えられたことのチップ。
    /// - Parameter policy: 変えた先の名前（`QuotePolicy.title`）。
    public static func quotePolicyChanged(to policy: String) -> String {
        "引用できる人を“\(policy)”に変更しました"
    }

    public static let quotePolicyFailure = "引用できる人を変更できませんでした"
    public static let quoteRevoked = "引用を取り消しました"
    public static let quoteRevokeFailure = "引用を取り消せませんでした"

    /// ユーザーのメニューで、その人を自動翻訳の対象から外したか戻したかのチップ。
    public static func autoTranslation(handle: String, isExcluded: Bool) -> String {
        isExcluded ? "\(handle)を自動翻訳しません" : "\(handle)を自動翻訳します"
    }

    public static let noteSaved = "メモを保存しました"
    public static let noteDeleted = "メモを削除しました"
    public static let reported = "通報しました"

    /// 投稿欄でリンクのタイトルを読んでいる間、「操作の状況」の進行中に並べる名前。
    public static let linkTitleLoading = "タイトルを読み込み中"
    /// リンクのタイトルを付けられなかった理由。ページを読めなかった。
    public static let linkPageUnreadable = "リンク先のページを読み込めませんでした。"
    /// リンクのタイトルを付けられなかった理由。ページにタイトルがなかった。
    public static let linkPageNoTitle = "リンク先のページにタイトルがありませんでした。"

    /// ログアウトされたアカウントのリストの、読み込めない理由。
    public static let reauthenticationListMessage = "ログインし直すと読み込めます。"
    /// リンクのメニューの「プロフィールとして開く」で、リンク先がプロフィールとして見つからなかった理由。
    public static let linkProfileNotFound = "リンク先のプロフィールが見つかりませんでした。"

    /// 投稿欄で投稿するアカウントを替えたとき、替えた先のアカウントで返信先か引用元を引用できない理由。
    public static func cannotQuote(username: String) -> String {
        "@\(username)では引用元の投稿を引用できません。"
    }

    /// 投稿欄で投稿するアカウントを替えたとき、替えた先のアカウントから返信先か引用元が見えない理由。
    public static func cannotSee(username: String, isReply: Bool) -> String {
        "@\(username)からは\(isReply ? "返信先" : "引用元")の投稿を表示できません。"
    }

    /// 操作の失敗の見出し。
    public enum Failure {
        public static let postingDefaults = "投稿のデフォルトを変更できませんでした"
        public static let openProfile = "プロフィールを開けませんでした"
        public static let loadProfile = "プロフィールを読み込めませんでした"
        public static let notificationPolicy = "通知のフィルタリングを変更できませんでした"
        public static let openStatus = "投稿を開けませんでした"
        public static let switchWritingAccount = "投稿するアカウントを替えられませんでした"
        /// 書いていたアカウントからログアウトして投稿欄を今のアカウントに戻したとき、返信先か引用元を付け直せなかった。
        public static func droppedTarget(isReply: Bool) -> String {
            isReply ? "返信先を外しました" : "引用元を外しました"
        }
        public static let mention = "メンションできませんでした"
        public static let profileLink = "リンクを取得できませんでした"
        public static let startQuote = "引用を始められませんでした"
        public static let startEditing = "編集を始められませんでした"
        public static let startRedrafting = "書き直しを始められませんでした"
        public static let dismissNotification = "通知を削除できませんでした"
        public static let vote = "投票できませんでした"
        public static let refreshPoll = "投票の結果を更新できませんでした"
        public static let open = "開けませんでした"
        /// お知らせのリアクション。投稿のリアクションの失敗（`StatusInteractions.Action.failureTitle`）と同じ文言。
        public static let announcementReaction = "リアクションを変更できませんでした"
    }
}

extension NotificationRequestDecision {
    /// 保留中の通知に答えられなかったときの見出し。
    public var failureTitle: String {
        switch self {
        case .accept: "通知を受け入れられませんでした"
        case .dismiss: "通知を無視できませんでした"
        }
    }
}

extension FollowRequestDecision {
    /// フォローリクエストに返事できなかったときの見出し。
    public var failureTitle: String {
        switch self {
        case .authorize: "フォローリクエストを承認できませんでした"
        case .reject: "フォローリクエストを却下できませんでした"
        }
    }
}

extension UserHandlePart {
    /// ユーザーのメニューで、ハンドルのこの部分をコピーできなかったときの見出し。
    public var copyFailureTitle: String {
        switch self {
        case .handle: "ハンドルをコピーできませんでした"
        case .username: "ユーザー名をコピーできませんでした"
        case .server: "サーバーをコピーできませんでした"
        }
    }
}

/// ハッシュタグのフォロー、プロフィールでの紹介、ミュートを変えたときの文言。今のアカウントでも、ほかのアカウントでも同じ文言を使う。
public enum HashtagChangeTexts {
    /// - Parameter name: `#`を除いた名前。
    public static func followed(_ name: String) -> String {
        "#\(name)をフォローしました"
    }

    public static func unfollowed(_ name: String) -> String {
        "#\(name)のフォローを外しました"
    }

    public static func featured(_ name: String) -> String {
        "#\(name)をプロフィールで紹介しました"
    }

    public static func unfeatured(_ name: String) -> String {
        "#\(name)をプロフィールから外しました"
    }

    public static func muted(_ name: String) -> String {
        "#\(name)をミュートしました"
    }

    public static func unmuted(_ name: String) -> String {
        "#\(name)のミュートを解除しました"
    }

    public static let followFailure = "ハッシュタグをフォローできませんでした"
    public static let unfollowFailure = "ハッシュタグのフォローを外せませんでした"
    public static let featureFailure = "プロフィールでの紹介を変更できませんでした"
    public static let muteFailure = "ミュートを変更できませんでした"
}

/// タイムラインの「タブ」ボタンのメニューと、タブの名前を変えるアラート、タブを選ぶメニューの文言。
public enum TabMenuTexts {
    /// 右上の「タブ」ボタン。入り切らずにまとめられたときにも出る名前。
    public static let button = "タブ"
    public static let rename = "名前を変える"
    public static let remove = "タブから外す"
    public static let removed = "タブから外しました"
    public static let add = "タブに追加"
    public static let addSubtitle = "切り替えタブに入ります"
    public static let added = "タブに追加しました"
    /// タブを選ぶメニューの、並びの設定を開く項目。
    public static let customize = "カスタマイズ"

    /// タブの名前を変えるアラート。
    public enum Rename {
        public static let title = "タブの名前"

        /// - Parameter defaultTitle: 空にしたときに出す既定の名前。
        public static func message(defaultTitle: String) -> String {
            "空にすると“\(defaultTitle)”に戻ります"
        }

        public static let cancel = "キャンセル"
        public static let save = "保存"
    }
}
