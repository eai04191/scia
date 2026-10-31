import Foundation

/// 自分のリスト。決まりはdocs/lists.mdにある。
/// https://docs.joinmastodon.org/entities/List/
public struct MastodonList: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// どの返信をリストに流すか。返さないサーバーや、知らない値ではnil。
    public let repliesPolicy: ListRepliesPolicy?
    /// メンバーの投稿をホームに流さないか。返さないサーバー（Mastodon 4.2より前）ではnil。
    public let exclusive: Bool?

    public init(id: String, title: String, repliesPolicy: ListRepliesPolicy? = nil, exclusive: Bool? = nil) {
        self.id = id
        self.title = title
        self.repliesPolicy = repliesPolicy
        self.exclusive = exclusive
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, repliesPolicy, exclusive
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        // 知らない値でもリストそのものは読めるよう、文字列で読んでから当てはめる。
        repliesPolicy = container.decodeLossyIfPresent(String.self, forKey: .repliesPolicy).flatMap(ListRepliesPolicy.init(rawValue:))
        exclusive = container.decodeLossyIfPresent(Bool.self, forKey: .exclusive)
    }
}

/// リストに流す返信。`rawValue`はAPIの`replies_policy`の値。
public enum ListRepliesPolicy: String, CaseIterable, Sendable {
    /// フォローしている誰かへの返信。
    case followed
    /// リストのメンバーへの返信。
    case list
    /// 返信を流さない。`Optional.none`と取り違えないよう、名前を変えている。
    case noReplies = "none"

    /// 選ぶときの名前。Mastodonのwebの日本語の文言に揃える。
    public var title: String {
        switch self {
        case .followed: "フォロー中のユーザー全員"
        case .list: "リストのメンバー"
        case .noReplies: "表示しない"
        }
    }
}
