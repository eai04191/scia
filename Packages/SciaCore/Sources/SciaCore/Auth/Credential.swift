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

    public init(instance: URL, accessToken: String, clientID: String, clientSecret: String, accountID: String, username: String) {
        self.instance = instance
        self.accessToken = accessToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.accountID = accountID
        self.username = username
    }
}
