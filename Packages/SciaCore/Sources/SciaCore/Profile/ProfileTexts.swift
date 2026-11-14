/// プロフィールの画面と、そこから開くメモやプロフィールの編集で共通に使う文言。
/// 画面ごとの文言は`AccountNoteTexts`、`ProfileEditTexts`、`ReportTexts`にある。
public enum ProfileTexts {
    /// 書いた文字数。メモの欄と通報の補足で揃え、3桁の区切りを付けない。
    public static func characterCount(_ count: Int) -> String {
        "\(count)文字"
    }

    /// 変更を保存せずに閉じようとしたときの、確かめるシート。
    public enum Discard {
        public static let message = "変更を保存していません"
        public static let discard = "変更を破棄"
        public static let keepEditing = "編集を続ける"
    }
}

/// 自分にしか見えないメモの、書く画面とプロフィールの欄に出す文言。
public enum AccountNoteTexts {
    /// 書く画面の題と入力欄の読み上げ、プロフィールの欄の見出し。
    public static let title = "メモ"
    public static let save = "保存"
    public static let placeholder = "メモを追加"
    public static let saveFailure = "メモを保存できませんでした"
    /// プロフィールの文章のメニューの先頭に足す項目。
    public static let edit = "メモを編集"
    /// プロフィールの欄を押したときの、読み上げのヒント。
    public static let editHint = "メモを編集します。"

    /// 書く画面の入力欄の見出し。
    public static func header(acct: String) -> String {
        "@\(acct)についての自分にしか見えないメモ"
    }

    /// プロフィールの欄の読み上げ。
    public static func accessibilityLabel(note: String) -> String {
        "メモ、\(note)"
    }
}
