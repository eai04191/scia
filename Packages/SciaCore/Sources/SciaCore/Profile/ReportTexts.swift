/// 通報のシートに出す文言。理由の種類の名前と説明は`ReportCategory.title`と`detail`、補足の文字数は`ProfileTexts.characterCount(_:)`にある。
public enum ReportTexts {
    public static let title = "通報"
    public static let cancel = "キャンセル"
    public static let submit = "送信"
    /// 長押しした投稿から開いたときの、その投稿を添えるスイッチ。
    public static let includesStatus = "長押しした投稿を添える"
    public static let categorySection = "理由"
    public static let commentSection = "補足"
    public static let forward = "相手のサーバーにも送る"

    /// 転送のスイッチの下に出す説明。
    public static func forwardDetail(domain: String) -> String {
        "\(domain)の管理者にもこの通報を転送します。"
    }

    /// 違反したルールの区切り。
    public enum Rules {
        public static let section = "違反したルール"
        public static let loadFailure = "ルールを読み込めませんでした"
        public static let retry = "再試行"
        public static let empty = "このサーバーにはルールがありません"
    }
}
