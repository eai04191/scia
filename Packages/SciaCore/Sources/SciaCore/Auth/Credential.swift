public import Foundation

/// ログイン済みアカウントの認証情報。Keychainに保存する。
public struct Credential: Codable, Sendable, Equatable {
    public let instance: URL
    public let accessToken: String
    /// トークンの失効に使うため、登録したアプリの情報も残す。
    public let clientID: String
    public let clientSecret: String
    public let accountID: String
    /// `@`より前のユーザー名。表示に使う。
    public let username: String

    public init(instance: URL, accessToken: String, clientID: String, clientSecret: String, accountID: String, username: String) {
        self.instance = instance
        self.accessToken = accessToken
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.accountID = accountID
        self.username = username
    }
}
