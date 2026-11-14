/// サーバーのお知らせのシートに出す文言。
public enum AnnouncementTexts {
    public static let title = "サーバーのお知らせ"
    /// 読めなかったお知らせの行。
    public static let unreadable = "読めなかったお知らせ"
    /// 読み込みの失敗の見出し。お知らせのリストの上の行と、1件もないときの表示に使う。
    public static let loadFailure = "お知らせを読み込めませんでした"
    public static let retry = "再試行"
    public static let empty = "お知らせはありません"

    /// 日付の読み上げ。未読のお知らせは、未読であることを添える。
    public static func dateAccessibilityLabel(date: String, isUnread: Bool) -> String {
        isUnread ? "\(date)、未読" : date
    }
}
