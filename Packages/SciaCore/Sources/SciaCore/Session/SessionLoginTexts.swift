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

    /// 書きかけの投稿があるときに、切り替えるかを確かめるアラート。
    public enum Switching {
        public static func title(handle: String) -> String {
            "\(handle)に切り替えますか？"
        }

        public static let message = "書きかけの投稿は破棄されます。"
        public static let confirm = "切り替える"
    }

    /// 書きかけの投稿があるときに、アカウントを足すかを確かめるアラート。
    public enum Adding {
        public static let title = "アカウントを追加しますか？"
        public static let message = "ログインすると追加したアカウントに切り替わり、書きかけの投稿は破棄されます。"
        public static let confirm = "追加する"
    }

    /// ログアウトするかを確かめるアラート。
    public enum LoggingOut {
        public static func title(handle: String) -> String {
            "\(handle)からログアウトしますか？"
        }

        /// - Parameter discardsDraft: 書きかけの投稿がある。使っているアカウントを消すと、画面ごと作り直して下書きも消えるため、添える。
        public static func message(discardsDraft: Bool) -> String {
            "アカウントの情報はこのデバイスから削除されます。もう一度使うにはログインし直す必要があります。"
                + (discardsDraft ? "書きかけの投稿も破棄されます。" : "")
        }

        public static let confirm = "ログアウト"
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
