import Foundation
public import Observation

/// プロフィール画面の一覧の切り替え。
public enum ProfileTab: String, CaseIterable, Sendable {
    case posts
    case media
}

/// プロフィール画面の「投稿」に、何を混ぜるか。
public struct ProfilePostsFilter: Sendable, Equatable {
    public var showsReplies: Bool
    public var showsBoosts: Bool

    public init(showsReplies: Bool, showsBoosts: Bool) {
        self.showsReplies = showsReplies
        self.showsBoosts = showsBoosts
    }

    /// 既定の絞り込み。これと違えば、絞り込みのボタンで分かるようにする。
    public static let standard = ProfilePostsFilter(showsReplies: false, showsBoosts: true)
}

/// フォローのボタンに出す状態。
public enum FollowState: Equatable, Sendable {
    /// 自分のアカウント。ボタンを出さない。
    case myself
    /// 関係をまだ読んでいない。
    case unknown
    case notFollowing(locked: Bool)
    /// フォローの承認を待っている。
    case requested
    case following
    /// ブロックしている、またはされている。フォローできない。
    case blocked
}

/// プロフィール画面の状態。表示した時点で分かっているアカウントから始め、届いたものから差し替える。
@MainActor
@Observable
public final class ProfileStore {
    /// 通信の口。テストでは差し替える。
    public struct API: Sendable {
        public var account: @Sendable (String) async throws -> Account
        public var relationship: @Sendable (String) async throws -> Relationship?
        public var statuses: @Sendable (String, AccountStatusFilter, TimelineQuery) async throws -> [Status]
        public var follow: @Sendable (String) async throws -> Relationship
        public var unfollow: @Sendable (String) async throws -> Relationship

        public init(
            account: @escaping @Sendable (String) async throws -> Account,
            relationship: @escaping @Sendable (String) async throws -> Relationship?,
            statuses: @escaping @Sendable (String, AccountStatusFilter, TimelineQuery) async throws -> [Status],
            follow: @escaping @Sendable (String) async throws -> Relationship,
            unfollow: @escaping @Sendable (String) async throws -> Relationship
        ) {
            self.account = account
            self.relationship = relationship
            self.statuses = statuses
            self.follow = follow
            self.unfollow = unfollow
        }

        public init(client: MastodonClient) {
            self.init(
                account: { try await client.account($0) },
                relationship: { try await client.relationship(with: $0) },
                statuses: { try await client.accountStatuses($0, filter: $1, query: $2) },
                follow: { try await client.follow($0) },
                unfollow: { try await client.unfollow($0) }
            )
        }
    }

    public private(set) var account: Account
    public private(set) var relationship: Relationship?
    /// 固定された投稿。「投稿」の一覧の上に置く。
    public private(set) var pinned: [Status] = []
    /// フォローやフォローの解除を送っている途中。
    public private(set) var isChangingFollow = false
    public private(set) var tab: ProfileTab
    public private(set) var postsFilter: ProfilePostsFilter
    /// 今の一覧。切り替えるたびに作り直す。
    @ObservationIgnored public private(set) var timeline: TimelineStore

    private let isMyself: Bool
    private let api: API
    private let pageSize: Int

    public init(account: Account, myAccountID: String?, tab: ProfileTab = .posts, postsFilter: ProfilePostsFilter, pageSize: Int = 40, api: API) {
        self.account = account
        isMyself = account.id == myAccountID
        self.tab = tab
        self.postsFilter = postsFilter
        self.pageSize = pageSize
        self.api = api
        timeline = Self.makeTimeline(accountID: account.id, filter: Self.statusFilter(tab: tab, postsFilter: postsFilter), pageSize: pageSize, api: api)
    }

    public var followState: FollowState {
        if isMyself { return .myself }
        guard let relationship else { return .unknown }
        if relationship.blocking || relationship.blockedBy { return .blocked }
        if relationship.following { return .following }
        if relationship.requested { return .requested }
        return .notFollowing(locked: account.locked)
    }

    /// アカウント、関係、固定された投稿を並行して読み、届いたものから差し替える。どれかが失敗しても、他の結果は反映する。
    /// 最初に失敗したものを投げる。
    public func loadProfile() async throws {
        enum Loaded: Sendable {
            case account(Account)
            case relationship(Relationship?)
            case pinned([Status])
        }
        let id = account.id
        let api = api
        let pageSize = pageSize
        let firstError = await withTaskGroup(of: Result<Loaded, any Error>.self) { group -> (any Error)? in
            group.addTask { await Result { .account(try await api.account(id)) } }
            if !isMyself {
                group.addTask { await Result { .relationship(try await api.relationship(id)) } }
            }
            group.addTask { await Result { .pinned(try await api.statuses(id, AccountStatusFilter(pinned: true), TimelineQuery(limit: pageSize))) } }
            var firstError: (any Error)?
            for await result in group {
                switch result {
                case .success(.account(let account)): self.account = account
                case .success(.relationship(let relationship)): self.relationship = relationship
                case .success(.pinned(let pinned)): self.pinned = pinned
                case .failure(let error): firstError = firstError ?? error
                }
            }
            return firstError
        }
        if let firstError { throw firstError }
    }

    /// 一覧を切り替え、新しい一覧を返す。同じなら作り直さずnilを返す。
    public func select(_ tab: ProfileTab) -> TimelineStore? {
        guard tab != self.tab else { return nil }
        self.tab = tab
        return rebuildTimeline()
    }

    /// 「投稿」の絞り込みを変え、新しい一覧を返す。同じなら作り直さずnilを返す。
    public func setPostsFilter(_ filter: ProfilePostsFilter) -> TimelineStore? {
        guard filter != postsFilter else { return nil }
        postsFilter = filter
        return tab == .posts ? rebuildTimeline() : nil
    }

    /// 一覧の上に置く固定された投稿。「投稿」の一覧でだけ置く。
    public var displayedPinned: [Status] {
        tab == .posts ? pinned : []
    }

    /// フォローしていなければフォローし、フォロー中かリクエスト中なら外す。送っている途中なら何もしない。
    public func toggleFollow() async throws {
        guard !isChangingFollow else { return }
        let follows: Bool
        switch followState {
        case .notFollowing: follows = true
        case .following, .requested: follows = false
        case .myself, .unknown, .blocked: return
        }
        isChangingFollow = true
        defer { isChangingFollow = false }
        relationship = try await follows ? api.follow(account.id) : api.unfollow(account.id)
    }

    private func rebuildTimeline() -> TimelineStore {
        timeline = Self.makeTimeline(accountID: account.id, filter: Self.statusFilter(tab: tab, postsFilter: postsFilter), pageSize: pageSize, api: api)
        return timeline
    }

    static func statusFilter(tab: ProfileTab, postsFilter: ProfilePostsFilter) -> AccountStatusFilter {
        switch tab {
        case .posts: AccountStatusFilter(excludesReplies: !postsFilter.showsReplies, excludesReblogs: !postsFilter.showsBoosts)
        case .media: AccountStatusFilter(onlyMedia: true)
        }
    }

    private static func makeTimeline(accountID: String, filter: AccountStatusFilter, pageSize: Int, api: API) -> TimelineStore {
        TimelineStore(pageSize: pageSize) { query in
            TimelinePage(statuses: try await api.statuses(accountID, filter, query), isRegenerating: false)
        }
    }
}
