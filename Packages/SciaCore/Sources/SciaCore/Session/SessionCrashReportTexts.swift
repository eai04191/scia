/// クラッシュした投稿の隔離（docs/crash-quarantine.md）の、チップと報告の画面の文言。
public enum CrashReportTexts {
    /// 開発者に送る内容に書く、アプリの版とデバイスとOSの版。
    public static func environment(version: String, build: String, device: String, systemVersion: String) -> String {
        TextLists.joined(["Scia \(version) (\(build))", device, "iOS \(systemVersion)"])
    }

    /// 表示できない投稿があったことを伝えるチップ。
    public static let quarantinedChip = "表示できない投稿がありました"
    public static let quarantinedChipHint = "隠した投稿の詳細を表示します。"

    /// 報告のメールの件名。
    public static let mailSubject = "Scia クラッシュレポート"

    /// 報告の画面。
    public enum Screen {
        public static let title = "表示できない投稿"
        public static let close = "閉じる"
        public static let apology = "以前この投稿を読み込んだ際に問題が発生したため表示を中止しました。ご不便をおかけして申し訳ありません。"
        public static let request = "この投稿にはSciaが想定していないデータが含まれている可能性があります。原因を特定して修正するために開発者に情報を提供していただけませんか？"
        /// 報告する内容を読めなかった理由の前に添える文。
        public static let loadFailureLead = "報告する内容を読み込めませんでした。"
        public static let retry = "再試行"
        public static let contentHeader = "開発者に報告する内容"
        public static let includesDetail = "詳しいデータも送る"
        public static let detailNote = "本文の文字を置き換えたデータです。長いためメールでのみ送れます。"
        public static let sendByMail = "メールで報告"
        public static let sendByMastodon = "Mastodonのダイレクトで報告"
        public static let openInBrowser = "ブラウザで開く"
    }

    /// 報告を送り始められなかったときのアラート。
    public enum SendFailure {
        public static let mailTitle = "メールを開けませんでした"
        public static let mailMessage = "メールアプリを設定するかMastodonで報告してください。"
        public static let composeTitle = "投稿欄を開けませんでした"
        public static let composeMessage = "書きかけの投稿を投稿するか削除してください。"
    }
}
