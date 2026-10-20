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
    /// 関係を読めなかった。フォローのボタンの場所で、読めなかったことと再試行を示す。
    case loadFailed
    case notFollowing(locked: Bool)
    /// フォローの承認を待っている。
    case requested
    case following
    /// ブロックしている、またはされている。フォローできない。
    case blocked
}

/// プロフィールの読み込みで失敗したもの。読めたものはnil。
/// 知らせ方が違うため分けて返す。関係はフォローのボタンの場所で知らせ、アカウントと固定された投稿はログだけにする。
public struct ProfileLoadFailures: Sendable {
    public var account: (any Error)?
    public var relationship: (any Error)?
    public var pinned: (any Error)?

    public var isEmpty: Bool {
        account == nil && relationship == nil && pinned == nil
    }
}

/// プロフィール画面の状態。表示した時点で分かっているアカウントから始め、届いたものから差し替える。
@MainActor
@Observable
public final class ProfileStore {
    /// 通信の口。テストでは差し替える。
    public struct API: Sendable {
        public var account: @Sendable (String) async throws -> Account
        public var relationship: @Sendable (String) async throws -> Relationship?
        public var statuses: @Sendable (String, AccountStatusFilter, TimelineQuery) async throws -> TimelinePage
        public var follow: @Sendable (String) async throws -> Relationship
        public var unfollow: @Sendable (String) async throws -> Relationship

        public init(
            account: @escaping @Sendable (String) async throws -> Account,
            relationship: @escaping @Sendable (String) async throws -> Relationship?,
            statuses: @escaping @Sendable (String, AccountStatusFilter, TimelineQuery) async throws -> TimelinePage,
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
    /// 読み込む前は、前に同じ相手を開いたときに読んだ関係。
    public private(set) var relationship: Relationship? {
        didSet { relationshipCache[account.id] = relationship }
    }
    /// 固定された投稿。「投稿」の一覧の上に置く。フィルターで出さない投稿は除く。
    public var pinned: [Status] {
        let now = Date()
        return loadedPinned.filter { !filtering.verdict(for: $0, now: now).isHidden }
    }
    /// 読んだ固定された投稿。編集でフィルターに一致しなくなったら出せるよう、隠す投稿も持つ。
    private var loadedPinned: [Status] = []
    /// 固定された投稿を読み終えた。読めなかったときも含む。一覧を固定された投稿と一緒に出すために、これを待つ。
    public private(set) var isPinnedSettled = false
    /// 関係を読めず、まだ読み直せていない。
    public private(set) var relationshipFailed = false
    /// 読めなかった関係を読み直している途中。
    public private(set) var isReloadingRelationship = false
    /// フォローやフォローの解除を送っている途中。
    public private(set) var isChangingFollow = false
    public private(set) var tab: ProfileTab
    public private(set) var postsFilter: ProfilePostsFilter
    /// 今の一覧。切り替えるたびに作り直す。
    @ObservationIgnored public private(set) var timeline: TimelineStore

    /// フォローを変えた回数。前に読んだ関係から始めると、関係を読み直している途中でもフォローを送れるため、
    /// フォローより前に頼んだ読み直しの応答が後から届いたら、古い関係として捨てる。
    private var followChanges = 0
    /// 削除した投稿のID。削除の前に読み始めた固定された投稿の応答で、戻さないようにする。
    private var deletedIDs: Set<Status.ID> = []
    private let isMyself: Bool
    /// プロフィールの一覧に当てるサーバーのフィルター。
    public let filtering: StatusFiltering
    private let api: API
    private let pageSize: Int
    @ObservationIgnored private let relationshipCache: RelationshipCache

    public init(
        account: Account,
        myAccountID: String?,
        tab: ProfileTab = .posts,
        postsFilter: ProfilePostsFilter,
        pageSize: Int = 40,
        relationshipCache: RelationshipCache = RelationshipCache(),
        api: API
    ) {
        self.account = account
        isMyself = account.id == myAccountID
        self.relationshipCache = relationshipCache
        relationship = isMyself ? nil : relationshipCache[account.id]
        filtering = StatusFiltering(context: .account, myAccountID: myAccountID)
        self.tab = tab
        self.postsFilter = postsFilter
        self.pageSize = pageSize
        self.api = api
        timeline = Self.makeTimeline(accountID: account.id, filter: Self.statusFilter(tab: tab, postsFilter: postsFilter), filtering: filtering, pageSize: pageSize, api: api)
    }

    public var followState: FollowState {
        if isMyself { return .myself }
        guard let relationship else { return relationshipFailed ? .loadFailed : .unknown }
        if relationship.blocking || relationship.blockedBy { return .blocked }
        if relationship.following { return .following }
        if relationship.requested { return .requested }
        return .notFollowing(locked: account.locked)
    }

    /// アカウント、関係、固定された投稿を並行して読み、届いたものから差し替える。どれかが失敗しても、他の結果は反映する。
    /// 失敗したものを、どれが失敗したか分けて返す。
    public func loadProfile() async -> ProfileLoadFailures {
        enum Part: Sendable {
            case account
            case relationship
            case pinned
        }
        enum Loaded: Sendable {
            case account(Account)
            case relationship(Relationship?)
            case pinned([Status])
        }
        let id = account.id
        let api = api
        let pageSize = pageSize
        let followChangesAtRequest = followChanges
        return await withTaskGroup(of: (Part, Result<Loaded, any Error>).self) { group -> ProfileLoadFailures in
            group.addTask { (.account, await Result { .account(try await api.account(id)) }) }
            if !isMyself {
                group.addTask { (.relationship, await Result { .relationship(try await api.relationship(id)) }) }
            }
            // 固定された投稿は一覧の補足なので、読めなかったものは並べない。読めなかったことはデコードの記録に残る。
            group.addTask { (.pinned, await Result { .pinned(try await api.statuses(id, AccountStatusFilter(pinned: true), TimelineQuery(limit: pageSize)).statuses) }) }
            var failures = ProfileLoadFailures()
            for await (part, result) in group {
                switch result {
                case .success(.account(let account)): self.account = account
                case .success(.relationship(let relationship)):
                    guard followChanges == followChangesAtRequest else { continue }
                    self.relationship = relationship
                    relationshipFailed = false
                case .success(.pinned(let pinned)):
                    loadedPinned = pinned.filter { !deletedIDs.contains($0.id) }
                    isPinnedSettled = true
                case .failure(let error):
                    switch part {
                    case .account: failures.account = error
                    case .relationship:
                        failures.relationship = error
                        relationshipFailed = relationship == nil
                    case .pinned:
                        failures.pinned = error
                        isPinnedSettled = true
                    }
                }
            }
            return failures
        }
    }

    /// 読めなかった関係を読み直す。失敗したら、読めなかったままにして投げる。読み直している途中なら何もしない。
    public func reloadRelationship() async throws {
        guard !isMyself, !isReloadingRelationship else { return }
        isReloadingRelationship = true
        defer { isReloadingRelationship = false }
        let followChangesAtRequest = followChanges
        let reloaded = try await api.relationship(account.id)
        guard followChanges == followChangesAtRequest else { return }
        relationship = reloaded
        relationshipFailed = false
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
    /// 送ったらtrue。フォローのAPIは関係だけを返し、フォロワー数は古いままなので、送ったら`reloadAccount()`で読み直す。
    @discardableResult
    public func toggleFollow() async throws -> Bool {
        guard !isChangingFollow else { return false }
        let follows: Bool
        switch followState {
        case .notFollowing: follows = true
        case .following, .requested: follows = false
        case .myself, .unknown, .loadFailed, .blocked: return false
        }
        isChangingFollow = true
        defer { isChangingFollow = false }
        relationship = try await follows ? api.follow(account.id) : api.unfollow(account.id)
        followChanges += 1
        return true
    }

    /// アカウントだけを読み直す。
    public func reloadAccount() async throws {
        account = try await api.account(account.id)
    }

    /// 固定された投稿と今の一覧の、IDが一致する投稿を書き換える。一覧のブーストは、中の元の投稿のIDでも一致させる。
    /// 固定できるのは本人の投稿だけで、ブーストは固定されないため、固定された投稿はIDだけで比べる。書き換えたものがあればtrue。
    @discardableResult
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) -> Bool {
        var changed = timeline.updateStatus(id, transform)
        loadedPinned = loadedPinned.map { status in
            guard status.id == id else { return status }
            changed = true
            return transform(status)
        }
        return changed
    }

    /// 削除された投稿を、固定された投稿と今の一覧から除く。除いたものがあればtrue。
    @discardableResult
    public func removeStatus(_ id: Status.ID) -> Bool {
        deletedIDs.insert(id)
        var changed = timeline.removeStatus(id)
        if loadedPinned.contains(where: { $0.id == id }) {
            loadedPinned.removeAll { $0.id == id }
            changed = true
        }
        return changed
    }

    private func rebuildTimeline() -> TimelineStore {
        timeline = Self.makeTimeline(accountID: account.id, filter: Self.statusFilter(tab: tab, postsFilter: postsFilter), filtering: filtering, pageSize: pageSize, api: api)
        return timeline
    }

    static func statusFilter(tab: ProfileTab, postsFilter: ProfilePostsFilter) -> AccountStatusFilter {
        switch tab {
        case .posts: AccountStatusFilter(excludesReplies: !postsFilter.showsReplies, excludesReblogs: !postsFilter.showsBoosts)
        case .media: AccountStatusFilter(onlyMedia: true)
        }
    }

    private static func makeTimeline(accountID: String, filter: AccountStatusFilter, filtering: StatusFiltering, pageSize: Int, api: API) -> TimelineStore {
        TimelineStore(pageSize: pageSize, filtering: filtering) { query in
            try await api.statuses(accountID, filter, query)
        }
    }
}
