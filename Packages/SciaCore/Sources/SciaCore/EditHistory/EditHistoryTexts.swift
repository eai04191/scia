/// 編集履歴の画面に出す文言。
public enum EditHistoryTexts {
    public static let title = "編集履歴"
    public static let loadFailure = "編集履歴を読み込めませんでした"
    public static let retry = "再試行"
    /// 版の投票の選択肢の上に出す見出し。
    public static let pollOptionsTitle = "投票の選択肢"

    /// 版の注意書きの読み上げ。
    public static func spoilerAccessibilityLabel(_ text: String) -> String {
        "\(PostTexts.contentWarningLabel)、\(text)"
    }

    /// 差分の読み上げで、足した部分。色と線は読み上げられないため、言葉で示す。
    public static func insertedAccessibilityText(_ text: String) -> String {
        "追加：\(text)"
    }

    /// 差分の読み上げで、消した部分。
    public static func removedAccessibilityText(_ text: String) -> String {
        "削除：\(text)"
    }

    /// 差分の読み上げで、文字を変えずに段落を分けた位置。
    public static let insertedParagraphBreak = "追加：段落の区切り"
}
