public import Foundation

public struct Status: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let account: Account
    /// Mastodonが返すHTML文字列。リッチテキストへの変換は表示層で行う。
    public let content: String
    public let spoilerText: String
    public let url: URL?
    /// ブーストの場合、ブーストされた元の投稿。構造体は自分自身を直接持てないため、参照型の箱に入れる。
    private let reblogBox: StatusBox?

    public init(
        id: String,
        createdAt: Date,
        account: Account,
        content: String,
        spoilerText: String,
        url: URL?,
        reblog: Status? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.account = account
        self.content = content
        self.spoilerText = spoilerText
        self.url = url
        reblogBox = reblog.map(StatusBox.init)
    }

    public var reblog: Status? { reblogBox?.value }

    /// 画面に出す投稿。ブーストなら元の投稿、そうでなければ自身。
    public var displayed: Status { reblog ?? self }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, account, content, spoilerText, url
        case reblogBox = "reblog"
    }
}

final class StatusBox: Codable, Hashable, Sendable {
    let value: Status

    init(_ value: Status) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        value = try Status(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }

    static func == (lhs: StatusBox, rhs: StatusBox) -> Bool {
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}
