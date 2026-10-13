public import Foundation

/// https://docs.joinmastodon.org/entities/Status/#Mention
public struct Mention: Codable, Hashable, Sendable {
    public let id: String
    public let username: String
    public let url: URL
    /// ローカルのユーザーならusername、リモートならusername@domain。
    public let acct: String

    public init(id: String, username: String, url: URL, acct: String) {
        self.id = id
        self.username = username
        self.url = url
        self.acct = acct
    }
}

/// https://docs.joinmastodon.org/entities/Status/#Tag
public struct Tag: Codable, Hashable, Sendable {
    /// `#`を除いた名前。
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}
