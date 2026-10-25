public import Foundation

/// https://docs.joinmastodon.org/entities/Status/#Mention
public struct Mention: Codable, Hashable, Sendable {
    public let id: String
    public let username: String
    /// サーバーによっては空で返るため、読めなければnil。アプリ内ではIDでプロフィールを開くため、なくても困らない。
    public let url: URL?
    /// ローカルのユーザーならusername、リモートならusername@domain。
    public let acct: String

    public init(id: String, username: String, url: URL?, acct: String) {
        self.id = id
        self.username = username
        self.url = url
        self.acct = acct
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        url = container.decodeURL(.destination, forKey: .url)
        acct = try container.decode(String.self, forKey: .acct)
    }
}

/// https://docs.joinmastodon.org/entities/Status/#Tag
public struct Tag: Codable, Hashable, Sendable {
    /// `#`を除いた名前。
    public let name: String
    /// サーバーによっては空で返るため、読めなければnil。
    public let url: URL?

    public init(name: String, url: URL?) {
        self.name = name
        self.url = url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = container.decodeURL(.destination, forKey: .url)
    }
}
