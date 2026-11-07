public import Foundation
public import Observation

/// プロフィール画面のタイムラインの切り替え。
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
/// 知らせ方が違うため分けて返す。関係はフォローのボタンの場所で知らせ、アカウントとヘッダーの棚（固定された投稿、注目のハッシュタグ、紹介しているユーザー）はログだけにする。
public struct ProfileLoadFailures: Sendable {
    public var account: (any Error)?
    public var relationship: (any Error)?
    public var pinned: (any Error)?
    public var featuredTags: (any Error)?
    public var endorsements: (any Error)?

    public var isEmpty: Bool {
        all.isEmpty
    }

    /// 失敗したものを、ログに残す名前と並べる。
    public var all: [(part: String, error: any Error)] {
        [("account", account), ("relationship", relationship), ("pinned", pinned), ("featuredTags", featuredTags), ("endorsements", endorsements)]
            .compactMap { part, error in error.map { (part, $0) } }
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
        /// アカウントがプロフィールに載せているハッシュタグ。
        public var featuredTags: @Sendable (String) async throws -> [FeaturedTag]
        /// アカウントがプロフィールで紹介している人の、最初のページ。
        public var endorsements: @Sendable (String, Int) async throws -> AccountListPage

        public init(
            account: @escaping @Sendable (String) async throws -> Account,
            relationship: @escaping @Sendable (String) async throws -> Relationship?,
            statuses: @escaping @Sendable (String, AccountStatusFilter, TimelineQuery) async throws -> TimelinePage,
            follow: @escaping @Sendable (String) async throws -> Relationship,
            unfollow: @escaping @Sendable (String) async throws -> Relationship,
            featuredTags: @escaping @Sendable (String) async throws -> [FeaturedTag] = { _ in [] },
            endorsements: @escaping @Sendable (String, Int) async throws -> AccountListPage = { _, _ in AccountListPage(accounts: [], nextMaxID: nil) }
        ) {
            self.account = account
            self.relationship = relationship
            self.statuses = statuses
            self.follow = follow
            self.unfollow = unfollow
            self.featuredTags = featuredTags
            self.endorsements = endorsements
        }

        public init(client: MastodonClient) {
            self.init(
                account: { try await client.account($0) },
                relationship: { try await client.relationship(with: $0) },
                statuses: { try await client.accountStatuses($0, filter: $1, query: $2) },
                follow: { try await client.follow($0) },
                unfollow: { try await client.unfollow($0) },
                featuredTags: { try await client.featuredTags(of: $0) },
                endorsements: { try await client.accounts(in: .endorsements(accountID: $0), maxID: nil, limit: $1) }
            )
        }
    }

    public private(set) var account: Account
    /// 読み込む前は、前に同じ相手を開いたときに読んだ関係。
    public private(set) var relationship: Relationship? {
        didSet { relationshipCache[account.id] = relationship }
    }
    /// 固定された投稿。ヘッダーの下に棚として並べる。フィルターで出さない投稿は除く。
    public var pinned: [Status] {
        let now = now()
        return loadedPinned.filter { !filtering.verdict(for: $0, now: now).isHidden }
    }
    /// 読んだ固定された投稿。編集でフィルターに一致しなくなったら出せるよう、隠す投稿も持つ。
    private var loadedPinned: [Status] = []
    /// 固定された投稿を読み終えた。読めなかったときも含む。
    private var isPinnedSettled = false
    /// プロフィールに載せているハッシュタグ。サーバーが返した順。読めなければ空。
    public private(set) var featuredTags: [FeaturedTag] = []
    /// プロフィールで紹介している人の、最初のページ。読めなければ空。
    public private(set) var endorsements: [Account] = []
    /// 紹介している人に、最初のページより後の続きがある。
    public private(set) var hasMoreEndorsements = false
    /// 注目のハッシュタグと紹介している人を読み終えた。読めなかったときも含む。
    private var isFeaturedSettled = false
    /// ヘッダーの棚（固定された投稿、注目のハッシュタグ、紹介している人）を読み終えた。読めなかったときも含む。
    /// 棚が後から現れてタイムラインを押し下げないよう、タイムラインはこれを待って出す。
    public var isShelvesSettled: Bool {
        isPinnedSettled && isFeaturedSettled
    }
    /// 関係を読めず、まだ読み直せていない。
    public private(set) var relationshipFailed = false
    /// 読めなかった関係を読み直している途中。
    public private(set) var isReloadingRelationship = false
    /// フォローやフォローの解除を送っている途中。
    public private(set) var isChangingFollow = false
    public private(set) var tab: ProfileTab
    public private(set) var postsFilter: ProfilePostsFilter
    /// 今のタイムライン。切り替えるたびに作り直す。
    @ObservationIgnored public private(set) var timeline: TimelineStore

    /// フォローを変えた回数。前に読んだ関係から始めると、関係を読み直している途中でもフォローを送れるため、
    /// フォローより前に頼んだ読み直しの応答が後から届いたら、古い関係として捨てる。
    private var followChanges = 0
    /// 固定された投稿を読み始めた回数。固定と解除を続けて押すと読み直しが重なるため、遅れて届いた古い応答を捨てる。
    private var pinnedLoads = 0
    /// 注目のハッシュタグと紹介している人を読み始めた回数。プロフィールで紹介したり外したりして読み直しが重なったとき、遅れて届いた古い応答を捨てる。
    private var featuredLoads = 0
    /// アカウントを読み始めたか、編集したものを反映した回数。フォローしたあとの読み直しや保存した編集より前に頼んだ読み込みが、
    /// 遅れて届いても古い数や内容で戻さない。
    private var accountChanges = 0
    /// 削除した投稿のID。削除の前に読み始めた固定された投稿の応答で、戻さないようにする。
    private var deletedIDs: Set<Status.ID> = []
    private let isMyself: Bool
    /// プロフィールのタイムラインに当てるサーバーのフィルター。
    public let filtering: StatusFiltering
    private let api: API
    private let pageSize: Int
    @ObservationIgnored private let relationshipCache: RelationshipCache
    /// フィルターの期限と比べる今の日付。
    @ObservationIgnored private let now: @MainActor () -> Date

    public init(
        account: Account,
        myAccountID: String?,
        tab: ProfileTab = .posts,
        postsFilter: ProfilePostsFilter,
        pageSize: Int = 40,
        relationshipCache: RelationshipCache,
        now: @escaping @MainActor () -> Date = SystemTime.now,
        api: API
    ) {
        self.now = now
        self.account = account
        isMyself = account.id == myAccountID
        self.relationshipCache = relationshipCache
        relationship = relationshipCache[account.id]
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

    /// アカウント、関係、ヘッダーの棚を並行して読み、届いたものから差し替える。どれかが失敗しても、他の結果は反映する。
    /// 失敗したものは分けて返す。
    public func loadProfile() async -> ProfileLoadFailures {
        enum Part: Sendable {
            case account
            case relationship
            case pinned
            case featuredTags
            case endorsements
        }
        enum Loaded: Sendable {
            case account(Account)
            case relationship(Relationship?)
            case pinned([Status])
            case featuredTags([FeaturedTag])
            case endorsements(AccountListPage)
        }
        let id = account.id
        let api = api
        let pageSize = pageSize
        let followChangesAtRequest = followChanges
        accountChanges += 1
        let accountChange = accountChanges
        pinnedLoads += 1
        let pinnedLoad = pinnedLoads
        featuredLoads += 1
        let featuredLoad = featuredLoads
        // 注目のハッシュタグと紹介している人は、両方が届いてからタイムラインを出す。
        var featuredPending = 2
        return await withTaskGroup(of: (Part, Result<Loaded, any Error>).self) { group -> ProfileLoadFailures in
            group.addTask { (.account, await Result { .account(try await api.account(id)) }) }
            // 自分のプロフィールでも読む。自分に書いたメモが関係に入って返るため。
            group.addTask { (.relationship, await Result { .relationship(try await api.relationship(id)) }) }
            // 固定された投稿はタイムラインの補足なので、読めなかったものは並べない。読めなかったことはデコードの記録に残る。
            group.addTask { (.pinned, await Result { .pinned(try await api.statuses(id, AccountStatusFilter(pinned: true), TimelineQuery(limit: pageSize)).statuses) }) }
            group.addTask { (.featuredTags, await Result { .featuredTags(try await api.featuredTags(id)) }) }
            // 4.4より前のサーバーは、ほかの人の紹介している人を返さない。読めなかったものとして、棚を出さない。
            group.addTask { (.endorsements, await Result { .endorsements(try await api.endorsements(id, Self.endorsementsPageSize)) }) }
            var failures = ProfileLoadFailures()
            for await (part, result) in group {
                switch result {
                case .success(.account(let account)):
                    guard accountChange == accountChanges else { continue }
                    self.account = account
                case .success(.relationship(let relationship)):
                    guard followChanges == followChangesAtRequest else { continue }
                    self.relationship = relationship
                    relationshipFailed = false
                case .success(.pinned(let pinned)):
                    // あとから読み始めた読み直しがあれば、その結果に任せる。タイムラインを出すのは待たせない。
                    if pinnedLoad == pinnedLoads {
                        loadedPinned = pinned.filter { !deletedIDs.contains($0.id) }
                    }
                    isPinnedSettled = true
                case .success(.featuredTags(let tags)):
                    if featuredLoad == featuredLoads {
                        featuredTags = tags
                    }
                    featuredPending -= 1
                case .success(.endorsements(let page)):
                    if featuredLoad == featuredLoads {
                        endorsements = page.accounts
                        hasMoreEndorsements = page.nextMaxID != nil
                    }
                    featuredPending -= 1
                case .failure(let error):
                    switch part {
                    case .account: failures.account = error
                    case .relationship:
                        failures.relationship = error
                        relationshipFailed = relationship == nil
                    case .pinned:
                        failures.pinned = error
                        isPinnedSettled = true
                    case .featuredTags:
                        failures.featuredTags = error
                        featuredPending -= 1
                    case .endorsements:
                        failures.endorsements = error
                        featuredPending -= 1
                    }
                }
                if featuredPending == 0 {
                    isFeaturedSettled = true
                }
            }
            return failures
        }
    }

    /// 固定された投稿だけを読み直す。自分の投稿をプロフィールに固定したり外したりしたあとに呼ぶ。
    /// 固定した順にどう並ぶかはサーバーが決めるため、手元で差し込まずに読み直す。
    /// どの投稿をどの順に並べるかだけを応答に合わせ、前から並べていた投稿は手元のものを残す。待つ間に`updateStatus`で反映したお気に入りなどを、読み始めた時点の応答で戻さないため。
    /// あとから読み始めた読み直しがあれば、この応答は捨てる。
    public func reloadPinned() async throws {
        pinnedLoads += 1
        let pinnedLoad = pinnedLoads
        let pinned = try await api.statuses(account.id, AccountStatusFilter(pinned: true), TimelineQuery(limit: pageSize)).statuses
        guard pinnedLoad == pinnedLoads else { return }
        let current = Dictionary(loadedPinned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loadedPinned = pinned.filter { !deletedIDs.contains($0.id) }.map { current[$0.id] ?? $0 }
        isPinnedSettled = true
    }

    /// 注目のハッシュタグと紹介している人を読み直す。自分のプロフィールで、載せるものを変えたあとに呼ぶ。
    /// 読めなかったものは前のまま残し、読めなかったものがあれば投げる。あとから読み始めた読み直しがあれば、この応答は捨てる。
    public func reloadFeatured() async throws {
        featuredLoads += 1
        let featuredLoad = featuredLoads
        let id = account.id
        let api = api
        async let tags = Result { try await api.featuredTags(id) }
        async let page = Result { try await api.endorsements(id, Self.endorsementsPageSize) }
        let (loadedTags, loadedPage) = await (tags, page)
        guard featuredLoad == featuredLoads else { return }
        if case .success(let tags) = loadedTags {
            featuredTags = tags
        }
        if case .success(let page) = loadedPage {
            endorsements = page.accounts
            hasMoreEndorsements = page.nextMaxID != nil
        }
        isFeaturedSettled = true
        _ = try loadedTags.get()
        _ = try loadedPage.get()
    }

    /// 紹介している人の棚に並べる数。続きは人のリストで読む。
    public static let endorsementsPageSize = 40

    /// 読めなかった関係を読み直す。失敗したら、読めなかったままにして投げる。読み直している途中なら何もしない。
    public func reloadRelationship() async throws {
        guard !isReloadingRelationship else { return }
        isReloadingRelationship = true
        defer { isReloadingRelationship = false }
        let followChangesAtRequest = followChanges
        let reloaded = try await api.relationship(account.id)
        guard followChanges == followChangesAtRequest else { return }
        relationship = reloaded
        relationshipFailed = false
    }

    /// タイムラインを切り替え、新しいタイムラインを返す。同じなら作り直さずnilを返す。
    public func select(_ tab: ProfileTab) -> TimelineStore? {
        guard tab != self.tab else { return nil }
        self.tab = tab
        return rebuildTimeline()
    }

    /// 「投稿」の絞り込みを変え、新しいタイムラインを返す。同じなら作り直さずnilを返す。
    public func setPostsFilter(_ filter: ProfilePostsFilter) -> TimelineStore? {
        guard filter != postsFilter else { return nil }
        postsFilter = filter
        return tab == .posts ? rebuildTimeline() : nil
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
        let followChangesAtRequest = followChanges
        let changed = try await follows ? api.follow(account.id) : api.unfollow(account.id)
        // 応答を待つ間に、ユーザーのメニューで関係を変えていたら（`apply`）、そちらが新しいので戻さない。
        guard followChanges == followChangesAtRequest else { return true }
        relationship = changed
        followChanges += 1
        return true
    }

    /// ユーザーのメニューなど、ほかの画面で変えた関係を反映する。前に頼んだ読み直しの応答が後から届いても、古い関係として捨てる。
    public func apply(_ relationship: Relationship) {
        guard relationship.id == account.id else { return }
        self.relationship = relationship
        relationshipFailed = false
        followChanges += 1
    }

    /// 編集して保存した自分のプロフィールを反映する。ほかのアカウントのものなら何もしない。
    public func apply(edited account: Account) {
        guard account.id == self.account.id else { return }
        self.account = account
        accountChanges += 1
    }

    /// アカウントだけを読み直す。
    /// あとから読み直しを頼んだか、編集したものを反映したら、この応答は捨てる。
    public func reloadAccount() async throws {
        accountChanges += 1
        let accountChange = accountChanges
        let reloaded = try await api.account(account.id)
        guard accountChange == accountChanges else { return }
        account = reloaded
    }

    /// 固定された投稿と今のタイムラインの、IDが一致する投稿を書き換える。タイムラインのブーストは、中の元の投稿のIDでも一致させる。
    /// 固定できるのは本人の投稿だけで、ブーストは固定されないため、固定された投稿はIDだけで比べる。書き換えたものがあればtrue。
    @discardableResult
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) -> Bool {
        var changed = timeline.updateStatus(id, transform)
        loadedPinned = loadedPinned.map { status in
            let updated = TimelineStore.updating(id, in: status, transform)
            if updated != status { changed = true }
            return updated
        }
        return changed
    }

    /// 削除された投稿を、固定された投稿と今のタイムラインから除く。除いたものがあればtrue。
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
