import Foundation

/// 自分のリスト。タブに置くのに使う名前とIDだけを読む。
/// https://docs.joinmastodon.org/entities/List/
public struct MastodonList: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
