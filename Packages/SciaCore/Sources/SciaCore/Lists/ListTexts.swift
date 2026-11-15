/// リストを作る、名前と設定を変える、消すときと、「リストに追加」と「メンバーを追加」のシートに出す文言。
/// 「リストに追加」の失敗は`ListMembershipModel.Operation.failureTitle`、返信の表示の選択肢は`ListRepliesPolicy.title`、消す確認は`Confirmation.deletingList(title:)`にある。
public enum ListTexts {
    /// リストを作るアラートの題。「リストに追加」のシートの、リストを作るボタンにも使う。
    public static let create = "リストを作成"
    /// リストを作るアラートの、作るボタン。
    public static let createAction = "作成"

    /// リストを作れなかったときの文言。`account`は、ほかのアカウントのリストを作るときの、そのアカウントの`@username`。
    public static func createFailure(account: String?) -> String {
        if let account {
            return "\(account)でリストを作成できませんでした"
        }
        return "リストを作成できませんでした"
    }

    /// 名前を変えるアラートの題と、名前の入力欄のプレースホルダ。
    public static let name = "リストの名前"
    /// 名前を変えるアラートの、保存するボタン。
    public static let saveName = "保存"
    public static let renameFailure = "リストの名前を変更できませんでした"
    public static let repliesPolicyFailure = "返信の表示を変更できませんでした"
    public static let exclusiveFailure = "“ホームに表示しない”を切り替えられませんでした"
    public static let deleteFailure = "リストを削除できませんでした"
    /// 名前を入れるアラートの、やめるボタン。
    public static let cancel = "キャンセル"

    /// リストのタイムラインの右上のメニュー。
    public enum Menu {
        /// メニューのボタンの名前。右上に入り切らず「さらに表示」にまとめられたときに出る。
        public static let button = "リスト"
        public static let rename = "名前を変える"
        public static let members = "メンバー"
        public static let repliesPolicy = "返信の表示"
        public static let exclusive = "ホームに表示しない"
        public static let delete = "削除"
    }

    /// 「メンバーを追加」のシート。
    public enum MemberSearch {
        public static let title = "メンバーを追加"
        /// 何も打っていないときに出す案内。
        public static let hint = "フォローしている人を名前かハンドルで探します。"
        public static let prompt = "フォローしている人を探す"
        public static let done = "完了"
    }

    /// 「リストに追加」のシート。
    public enum Membership {
        public static let title = "リストに追加"
        public static let done = "完了"
        public static let cancel = "キャンセル"
        public static let loadFailed = "読み込めませんでした"
        public static let reload = "再読み込み"
        /// ブロックしているかされているときに、リストの下に出す文言。
        public static let blocked = "ブロックしているかされているため、フォローもリストへの追加もできません。"
    }
}
