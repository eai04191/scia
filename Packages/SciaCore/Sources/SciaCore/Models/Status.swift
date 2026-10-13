import Foundation

public struct Status: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let account: Account
    /// Mastodonが返すHTML文字列。リッチテキストへの変換は表示層で行う。
    public let content: String
    public let spoilerText: String
    public let url: URL?
}
