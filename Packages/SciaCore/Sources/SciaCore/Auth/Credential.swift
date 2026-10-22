public import Foundation

/// ログイン済みアカウントの認証情報。Keychainに保存する。
public struct Credential: Codable, Sendable, Equatable, Identifiable {
    public let instance: URL
    public let accessToken: String
    /// トークンの失効に使うため、登録したアプリの情報も残す。
    public let clientID: String
    public let clientSecret: String
    public let accountID: String
    /// `@`より前のユーザー名。表示に使う。
    public let username: String

    /// インスタンスとアカウントIDで、アカウントを区別する。
    public var id: String { "\(instance.absoluteString)#\(accountID)" }

    /// `@alice@example.social`の形。アカウントの一覧に出す。
    public var handle: String { "@\(username)@\(instance.host() ?? instance.absoluteString)" }

    /// `acct`を、サーバー名を付けた`@username@domain`の形にする。Mastodonの`acct`は、同じサーバーのユーザーではサーバー名を含まないため、ログインしているサーバーの名前を付ける。
    /// サーバー名は`handle`と同じくログインしたアドレスから取る。ユーザーのIDにアドレスと別のドメイン（`LOCAL_DOMAIN`）を使うサーバーでは、IDとは違う形になる。
    /// 正しく出すには`api/v2/instance`の`domain`を持ち回る必要があり、アカウントの一覧の`handle`も同じ形で出しているため、そろえて読まない。
    public func handle(ofAcct acct: String) -> String {
        acct.contains("@") ? "@\(acct)" : "@\(acct)@\(instance.host() ?? instance.absoluteString)"
    }

    public init(instance: URL, accessToken: String, clientID: String, clientSecret: String, accountID: String, username: String) {
        self.instance = instance
        self.accessToken = accessToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.accountID = accountID
        self.username = username
    }
}
