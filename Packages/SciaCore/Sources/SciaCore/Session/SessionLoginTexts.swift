/// ログインの画面の文言。
public enum LoginTexts {
    public static let serverHeader = "サーバー"
    public static let serverFooter = "アカウントがあるMastodonのサーバーのアドレス"
    /// サーバーのリストの提供元を示す文。Markdownのリンクを含む。
    public static let serverListCredit = "サーバーのリストの提供: [FediDB](https://fedidb.com)"
    /// Safariのログイン状態を使わずにログインする項目。
    public static let privateLogin = "プライベート"
    public static let privateLoginSubtitle = "Safariのログイン状態を使わない"
    public static let logIn = "ログイン"
    /// アカウントを足すときの画面の題。
    public static let addAccountTitle = "アカウントを追加"
    public static let cancel = "キャンセル"
}

/// アカウントの切り替え、追加、ログアウト、ログインし直しの文言。
public enum AccountSwitchTexts {
    /// アカウントのメニューの、アカウントを足す項目。
    public static let addAccount = "アカウントを追加"
    public static let cancel = "キャンセル"

    /// ログアウトするかを確かめるアラート。
    public enum LoggingOut {
        public static func title(handle: String) -> String {
            "\(handle)からログアウトしますか？"
        }

        /// - Parameter discardsDraft: ログアウトするアカウントのサーバーの投稿の編集、削除して書き直す、予約の書き直しを書いている。ほかのアカウントでは続けられず、下書きを捨てるため、添える。
        public static func message(discardsDraft: Bool) -> String {
            "アカウントの情報はこのデバイスから削除されます。もう一度使うにはログインし直す必要があります。"
                + (discardsDraft ? "書きかけの投稿も破棄されます。" : "")
        }

        public static let confirm = "ログアウト"
    }

    /// この端末でログアウトしたアカウントで、開いたままのシートなどから送ろうとしたときの理由。端末から消したアカウントはログインし直しても戻さないので、「ログインし直す」は添えない。
    public static func removedAccount(handle: String) -> String {
        "\(handle)からはログアウトしました。"
    }

    public static let reauthenticationFailure = "ログインし直せませんでした"
    public static let logOutFailure = "ログアウトできませんでした"

    /// ログインし直しで、元とは別のアカウントでログインされた理由。
    public static func differentAccountLoggedIn(expected: String, actual: String) -> String {
        "\(actual)でログインされました。\(expected)でログインし直してください。"
    }

    /// 起動時にKeychainを読めず、アカウントを保存できない理由。
    public static let accountsUnavailable = "アカウントの情報を読み書きできません。アプリを再起動してください。"
}
