/// 投稿の一覧の種類。読み込み先、購読するストリーム、当てるフィルターの文脈、既読位置の保存先を決める。
/// タブに並べるもののほか、ハッシュタグのメニューから積んで開くものがある。
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
    /// あるアカウントの、ハッシュタグの付いた投稿。`name`は`#`を除いた名前。タブには置かず、ハッシュタグのメニューから開く。
    case accountHashtag(accountID: String, name: String)

    /// ログに残す名前。ハッシュタグの名前は、何に関心があるかが分かるので含めない（docs/logging.md）。
    public var name: String {
        switch self {
        case .home: "home"
        case .local: "local"
        case .federated: "federated"
        case .list(let id): "list:\(id)"
        case .hashtag: "hashtag"
        case .accountHashtag(let accountID, _): "account:\(accountID):hashtag"
        }
    }

    /// https://docs.joinmastodon.org/methods/streaming/#streams
    /// アカウントの投稿のストリームはないため、アカウントのハッシュタグはハッシュタグのストリームを購読し、`handling(ofStreamed:)`でそのアカウントの投稿に絞る。
    public var subscription: StreamingSubscription {
        switch self {
        case .home: .user
        case .local: StreamingSubscription(stream: "public:local")
        case .federated: StreamingSubscription(stream: "public")
        case .list(let id): .list(id)
        case .hashtag(let name), .accountHashtag(_, let name): .hashtag(name)
        }
    }

    public var isAccountHashtag: Bool {
        if case .accountHashtag = self { true } else { false }
    }

    /// ストリームで届いた投稿の扱い。
    public enum StreamedStatusHandling: Sendable, Equatable {
        /// 新着として入れる。
        case insert
        /// この一覧の投稿ではないので捨てる。
        case ignore
        /// 届いた投稿は入れず、最新から補う。ストリームがこの一覧の投稿の一部しか運ばないとき、届いた投稿を入れると補完の基準が先へ進み、
        /// その前のストリームに来なかった投稿を読まなくなるため。
        case fetchLatest
    }

    /// ストリームで届いた投稿を、この一覧でどう扱うか。
    /// アカウントのハッシュタグは、ハッシュタグのストリームを購読し、そのアカウントの投稿だけを扱う。Mastodonはハッシュタグのストリームに公開の投稿しか流さないが、
    /// アカウントの投稿のAPIは、ひかえめな公開や、見る権限のあるフォロワーのみの投稿も返すため、届いたら補う。
    public func handling(ofStreamed status: Status) -> StreamedStatusHandling {
        switch self {
        case .home, .local, .federated, .list, .hashtag: .insert
        case .accountHashtag(let accountID, _): status.account.id == accountID ? .fetchLatest : .ignore
        }
    }

    /// https://docs.joinmastodon.org/entities/Filter/#context
    /// `home`の文脈は、ホームとリストに当てる。ハッシュタグは、公式のWebクライアントと同じく`public`の文脈で当てる。
    /// アカウントのハッシュタグは、公式のWebクライアントと同じく、プロフィールの一覧と同じ`account`の文脈で当てる。
    public var filterContext: FilterResult.Context {
        switch self {
        case .home, .list: .home
        case .local, .federated, .hashtag: .public
        case .accountHashtag: .account
        }
    }

    /// サーバーに既読位置を保存する先。markerはホームと通知にしかないため、ほかの一覧ではnil。
    public var marker: MarkerTimeline? {
        switch self {
        case .home: .home
        case .local, .federated, .list, .hashtag, .accountHashtag: nil
        }
    }

    public func page(_ query: TimelineQuery, from client: MastodonClient) async throws -> TimelinePage {
        switch self {
        case .home: try await client.homeTimeline(query)
        case .local: try await client.publicTimeline(query, localOnly: true)
        case .federated: try await client.publicTimeline(query, localOnly: false)
        case .list(let id): try await client.listTimeline(id, query)
        case .hashtag(let name): try await client.hashtagTimeline(name, query)
        case .accountHashtag(let accountID, let name): try await client.accountStatuses(accountID, filter: AccountStatusFilter(tagged: name), query: query)
        }
    }
}
