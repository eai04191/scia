public import Foundation

public struct Status: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let account: Account
    /// Mastodonが返すHTML文字列。リッチテキストへの変換は表示層で行う。
    public let content: String
    public let spoilerText: String
    public let url: URL?

    public init(id: String, createdAt: Date, account: Account, content: String, spoilerText: String, url: URL?) {
        self.id = id
        self.createdAt = createdAt
        self.account = account
        self.content = content
        self.spoilerText = spoilerText
        self.url = url
    }
}
