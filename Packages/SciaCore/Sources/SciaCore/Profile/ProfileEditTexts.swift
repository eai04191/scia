/// 自分のプロフィールの編集の画面と、アイコンやヘッダー画像の切り抜きの画面に出す文言。
/// 変更を保存せずに閉じるときの確認は`ProfileTexts.Discard`にある。
public enum ProfileEditTexts {
    public static let title = "プロフィールを編集"
    public static let save = "保存"
    public static let saveFailure = "プロフィールを保存できませんでした"
    /// プロフィールを読めなかったときの、再試行のボタン。
    public static let retry = "再試行"
    /// 入力欄の下に出す、カスタム絵文字のパレットを開くボタンの読み上げ。
    public static let customEmoji = "カスタム絵文字"
    /// 補足情報、注目のハッシュタグ、紹介しているユーザーの行を消すボタン。
    public static let delete = "削除"

    /// 区切りの見出し。
    public enum Section {
        public static let displayName = "表示名"
        public static let note = "自己紹介"
        public static let fields = "補足情報"
        public static let featuredTags = "注目のハッシュタグ"
        public static let endorsements = "紹介しているユーザー"
    }

    /// 表示名の入力欄のプレースホルダと読み上げ。
    public static let displayName = "表示名"
    /// 自己紹介の入力欄のプレースホルダと読み上げ。
    public static let note = "自己紹介"

    /// 補足情報の行。
    public enum Field {
        public static let add = "補足情報を追加"
        public static let namePlaceholder = "ラベル"
        public static let nameAccessibilityLabel = "補足情報のラベル"
        public static let valuePlaceholder = "内容"
        public static let valueAccessibilityLabel = "補足情報の内容"
        /// 内容を書いて、ラベルを書いていない行があるときに、区切りの下に出す文言。
        public static let nameMissing = "内容を書いた行にはラベルも書いてください"

        /// ラベルか内容が長すぎる行があるときに、区切りの下に出す文言。
        public static func tooLong(limit: Int) -> String {
            "ラベルと内容は\(limit)文字までです"
        }
    }

    /// 注目のハッシュタグと紹介しているユーザーを足す入力欄。
    public enum AddField {
        public static let featuredTagPlaceholder = "ハッシュタグを追加"
        public static let featuredTagAccessibilityLabel = "注目のハッシュタグを追加"
        public static let endorsementPlaceholder = "ユーザーを追加"
        public static let endorsementAccessibilityLabel = "紹介するユーザーを追加"
    }

    /// 注目のハッシュタグと紹介しているユーザーの区切りを、読んでいる間と読めなかったときの行。
    public enum SectionLoad {
        public static let loading = "読み込み中"
        /// 読めなかった行の名前。選択すると再読み込みする。
        public static let reload = "再読み込み"

        /// 読めなかった行の、名前の下に出す説明。`reason`は失敗の理由の文。
        public static func failure(reason: String) -> String {
            "読み込めませんでした。\(reason)"
        }
    }

    /// フォローの承認とbotのスイッチの行。
    public enum Flag {
        public static let locked = "フォローを承認制にする"
        public static let lockedDetail = "フォローリクエストを承認した人だけがフォローできます"
        public static let bot = "botのアカウントとして示す"
        public static let botDetail = "自動で投稿するアカウントだとほかの人に伝わります"
    }

    /// アイコンとヘッダー画像のメニュー。
    public enum ImageMenu {
        public static let pick = "写真を選ぶ"
        public static let revert = "変更を取り消す"
        public static let remove = "削除"
    }

    /// 選んだ写真を読めなかったときの文言。
    public static let imageLoadFailure = "画像を読み込めませんでした"
    /// 選んだ写真を読めなかったときの理由。
    public static let imageUnreadable = "選んだ画像を読めませんでした。別の画像を選んでください。"

    /// 切り抜きの画面。
    public enum Crop {
        public static let done = "完了"
        /// ヘッダー画像の縦横比を選ぶ部品の読み上げ。
        public static let aspect = "縦横比"
    }
}

extension ProfileImage {
    /// アイコンかヘッダー画像の名前。編集の画面とプロフィールの画面の読み上げに使う。
    public var title: String {
        switch self {
        case .avatar: "アイコン"
        case .header: "ヘッダー画像"
        }
    }

    /// 切り抜きの画面の題。
    public var cropTitle: String {
        switch self {
        case .avatar: "アイコンを切り抜く"
        case .header: "ヘッダー画像を切り抜く"
        }
    }
}

extension ProfileImageChange {
    /// 編集の画面の、アイコンとヘッダー画像のボタンの読み上げの値。`isSet`は、今のプロフィールに画像があるか。
    public func accessibilityValue(isSet: Bool) -> String {
        switch self {
        case .keep: isSet ? "設定済み" : "未設定"
        case .replace: "変更あり"
        case .remove: "削除予定"
        }
    }
}
