/// タイムラインの画面に出す文言のうち、タイムラインの種類によらないもの。種類ごとに変わる文言は`TimelineTexts`、行の文言は`PostTexts`にある。
public enum TimelineScreenTexts {
    /// 投稿欄に触れられないときの入口のボタンと、キーコマンドの名前。
    public static let focusInlineCompose = "投稿欄に書く"

    /// 新着のボタンの読み上げ。
    /// - Parameter isLowerBound: 読み込んでいない新着があり、件数がそれ以上になる。
    public static func newArrivals(count: Int, isLowerBound: Bool) -> String {
        isLowerBound ? "\(count)件以上の新着" : "\(count)件の新着"
    }

    /// 1件もないときの表示のボタン。
    public static let reload = "再読み込み"
    /// 読み込めなかったときの表示のボタン。
    public static let retry = "再試行"
    /// 1件もないまま読み込めなかったときの見出し。
    public static let loadFailure = "読み込めませんでした"
    /// サーバーがホームを作り直しているときの見出しと説明。
    public static let regeneratingTitle = "ホームを準備しています"
    public static let regeneratingDetail = "しばらく使っていなかったため、サーバーがホームを作り直しています。少し待ってから読み込み直してください。"

    /// タイムラインの末尾に出す、続きを読み込めなかった文。理由の文言を埋める。
    public static func footerFailure(reason: String) -> String {
        "読み込めませんでした: \(reason)"
    }

    /// 読めなかった投稿や通知の行で、なぜ読めなかったかと、選択すると何が起きるか。
    /// - Parameter isCrashQuarantined: 表示中にアプリが終了したため隠している。
    /// - Parameter opensInBrowser: 選択するとブラウザで開ける。
    public static func unreadableDetail(isCrashQuarantined: Bool, opensInBrowser: Bool) -> String {
        if isCrashQuarantined {
            "表示中にSciaが終了したため隠しています。タップすると詳細を表示します。"
        } else if opensInBrowser {
            "サーバーから届いた内容を読めませんでした。タップするとブラウザで開きます。"
        } else {
            "サーバーから届いた内容を読めませんでした。"
        }
    }

    /// 選択すると再読み込みする行で、読み込めなかったとき。読み込んでいない投稿の行と、検索の結果の行に出す。
    public static let loadFailureTapToRetry = "読み込めませんでした。タップして再試行"
    /// 読み込んでいない投稿の行で、読み込んでいる間。
    public static let loading = "読み込み中"
    /// 読み込んでいない投稿の行。
    public static let loadGap = "読み込んでいない投稿を読み込む"

    /// 人の行を左へスワイプして外すボタン。リストのメンバーの画面でだけ出す。
    public static let removeAccount = "外す"

    /// 投稿をスワイプして出すメニューのボタン。
    public static let swipeMenu = "メニュー"
    /// 投稿をスワイプして出す、開いているアクションバーを閉じるボタン。
    public static let closeActionBar = "アクションバーを閉じる"

    /// メニューの境目より下の項目を入れるサブメニュー。
    public static let moreMenu = "その他"

    /// ハッシュタグのタイムラインの右上の、ハッシュタグのメニューを出すボタンの名前。
    public static let hashtagMenu = "ハッシュタグ"

    /// 保留中の通知の画面の右上の、通知のフィルタリングの設定を開くボタンの読み上げ。
    public static let notificationPolicy = "通知のフィルタリング"

    /// 投稿を選んでまとめて操作する間の、題とツールバー。
    public enum PostSelection {
        public static func title(count: Int) -> String {
            count == 0 ? "投稿を選択" : "\(count)件を選択"
        }

        public static let reblog = "ブースト"
        public static let share = "共有"
    }
}

extension TimelineTexts {
    /// 題の下に添える文字。ストリーミングにつながらない状態が続いていれば、そのことを後ろに並べる。どちらもなければnil。
    public func subtitle(showsStreamingOutage: Bool) -> String? {
        let parts = [subtitle, showsStreamingOutage ? "ストリーミング未接続" : nil].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

extension NotificationRequestDecision {
    /// 保留中の通知の行のスワイプと、画面の右上のボタンの名前。
    public var title: String {
        switch self {
        case .accept: "受け入れる"
        case .dismiss: "無視"
        }
    }
}

extension BatchReblogPlan {
    /// まとめてブーストを始める項目の名前。
    public var startTitle: String {
        "選んだ順にブースト（\(steps.count)件）"
    }

    /// まとめてブーストを始める項目に添える、付け直す投稿と飛ばす投稿の数。どちらもなければnil。
    public var startSubtitle: String? {
        var notes: [String] = []
        if reblogAgainCount > 0 { notes.append("ブースト済みの\(reblogAgainCount)件は付け直します") }
        if skippedCount > 0 { notes.append("ブーストできない\(skippedCount)件は飛ばします") }
        return notes.isEmpty ? nil : notes.joined(separator: "。")
    }
}

/// 選んだ投稿をまとめてブーストや共有をする間の、進み具合と確認の文言。ダウンロードを止めるかの確認は`MediaViewerTexts.Transfer`と同じ。
public enum BatchActionTexts {
    /// 同じ投稿へのほかの操作の結果を待っていたので、送らなかった理由。
    public static let busy = "この投稿へのほかの操作の結果を待っています。"
    /// 「操作の状況」の進行中の行。
    public static let reblogging = "ブースト中"
    public static let downloading = "ダウンロード中"
    /// 失敗の理由に並べる、失敗したところから続けるボタン。
    public static let resumeReblog = "続きからブースト"
    public static let close = "閉じる"
    public static let stopReblogTitle = "まとめてブーストを中止しますか？"
    public static let stopReblogMessage = "ブーストし終えた投稿はそのまま残ります。"
}
