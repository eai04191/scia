/// タブに並べる投稿の一覧の種類。読み込み先、購読するストリーム、当てるフィルターの文脈、既読位置の保存先を決める。
public enum TimelineFeed: Hashable, Sendable {
    case home
    /// このサーバーの公開の投稿。
    case local
    /// このサーバーが知っている公開の投稿すべて。
    case federated
    /// 自分のリスト。
    case list(id: String)
    /// ハッシュタグ。`name`は`#`を除いた名前。
    case hashtag(name: String)

    /// ログに残す名前。
    public var name: String {
        switch self {
        case .home: "home"
        case .local: "local"
        case .federated: "federated"
        case .list(let id): "list:\(id)"
        case .hashtag(let name): "hashtag:\(name)"
        }
    }

    /// https://docs.joinmastodon.org/methods/streaming/#streams
    public var subscription: StreamingSubscription {
        switch self {
        case .home: .user
        case .local: StreamingSubscription(stream: "public:local")
        case .federated: StreamingSubscription(stream: "public")
        case .list(let id): .list(id)
        case .hashtag(let name): .hashtag(name)
        }
    }

    /// https://docs.joinmastodon.org/entities/Filter/#context
    /// `home`の文脈は、ホームとリストに当てる。ハッシュタグは、公式のWebクライアントと同じく`public`の文脈で当てる。
    public var filterContext: FilterResult.Context {
        switch self {
        case .home, .list: .home
        case .local, .federated, .hashtag: .public
        }
    }

    /// サーバーに既読位置を保存する先。markerはホームと通知にしかないため、ほかの一覧ではnil。
    public var marker: MarkerTimeline? {
        switch self {
        case .home: .home
        case .local, .federated, .list, .hashtag: nil
        }
    }

    public func page(_ query: TimelineQuery, from client: MastodonClient) async throws -> TimelinePage {
        switch self {
        case .home: try await client.homeTimeline(query)
        case .local: try await client.publicTimeline(query, localOnly: true)
        case .federated: try await client.publicTimeline(query, localOnly: false)
        case .list(let id): try await client.listTimeline(id, query)
        case .hashtag(let name): try await client.hashtagTimeline(name, query)
        }
    }
}
