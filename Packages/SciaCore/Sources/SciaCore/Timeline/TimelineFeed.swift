/// タブに並べる投稿の一覧の種類。読み込み先、購読するストリーム、当てるフィルターの文脈、既読位置の保存先を決める。
public enum TimelineFeed: String, Sendable, CaseIterable {
    case home
    /// このサーバーの公開の投稿。
    case local
    /// このサーバーが知っている公開の投稿すべて。
    case federated

    /// https://docs.joinmastodon.org/methods/streaming/#streams
    public var subscription: StreamingSubscription {
        switch self {
        case .home: .user
        case .local: StreamingSubscription(stream: "public:local")
        case .federated: StreamingSubscription(stream: "public")
        }
    }

    /// https://docs.joinmastodon.org/entities/Filter/#context
    public var filterContext: FilterResult.Context {
        switch self {
        case .home: .home
        case .local, .federated: .public
        }
    }

    /// サーバーに既読位置を保存する先。markerはホームと通知にしかないため、公開タイムラインではnil。
    public var marker: MarkerTimeline? {
        switch self {
        case .home: .home
        case .local, .federated: nil
        }
    }

    public func page(_ query: TimelineQuery, from client: MastodonClient) async throws -> TimelinePage {
        switch self {
        case .home: try await client.homeTimeline(query)
        case .local: try await client.publicTimeline(query, localOnly: true)
        case .federated: try await client.publicTimeline(query, localOnly: false)
        }
    }
}
