/// 投稿のメニューの「別のアカウントで」で、ログインしているほかのアカウント1つとして、投稿と、投稿に出る人を操作する。決まりはdocs/menus.mdにある。
///
/// 投稿のIDはサーバーごとに違うため、そのアカウントのサーバーで、投稿のURIを探して引き直す。見つけた投稿はURIごとに覚え、
/// 操作の結果もその投稿に反映する。人は、見つけた投稿の投稿者とメンションの、そのサーバーでのIDで扱い、関係はこのアカウントで覚える。
/// 今のアカウントの一覧の投稿や、覚えている関係は変えない。
@MainActor
public final class OtherAccount {
    /// APIを呼ぶ口。テストでは差し替える。
    public struct Operations: Sendable {
        /// `resolve=true`で投稿を探す。
        public var search: @Sendable (String) async throws -> [Status]
        public var interactions: StatusInteractions.Operations
        /// そのアカウント自身のプロフィール。アカウントの行のアイコンに使う。
        public var profile: @Sendable () async throws -> Account
        /// そのアカウントと相手たちの関係をまとめて読む。
        public var relationships: RelationshipCache.Fetch
        /// 関係の変更を、そのサーバーでのIDの相手へ送る。
        public var changeRelation: @Sendable (UserRelationChange, String) async throws -> Relationship

        public init(
            search: @escaping @Sendable (String) async throws -> [Status],
            interactions: StatusInteractions.Operations,
            profile: @escaping @Sendable () async throws -> Account,
            relationships: @escaping RelationshipCache.Fetch,
            changeRelation: @escaping @Sendable (UserRelationChange, String) async throws -> Relationship
        ) {
            self.search = search
            self.interactions = interactions
            self.profile = profile
            self.relationships = relationships
            self.changeRelation = changeRelation
        }

        public init(client: MastodonClient) {
            let accountID = client.credential.accountID
            self.init(
                search: { try await client.search($0, category: .statuses, resolve: true, limit: 5).statuses },
                interactions: StatusInteractions.Operations(client: client),
                profile: { try await client.account(accountID) },
                relationships: { try await client.relationships($0) },
                changeRelation: { try await client.send($0, to: $1) }
            )
        }
    }

    /// そのアカウントで投稿を探した結果。
    public enum Lookup: Sendable {
        /// そのアカウントから見た投稿。
        case found(Status)
        /// 探せたが、そのアカウントからは見られない。
        case notFound
        /// 探せなかった。
        case failed(any Error)
    }

    public let credential: Credential
    private let operations: Operations
    private let tasks: TaskScope
    /// URIごとの、そのアカウントから見た投稿。
    private var statuses: [String: Status] = [:]
    /// URIごとの、最後に探せなかった理由。探せたら消す。
    private var failures: [String: any Error] = [:]
    /// URIごとの、操作で投稿を変えた回数。探している間に操作で変わったら、探す前の状態の結果で上書きしないために使う。
    private var revisions: [String: Int] = [:]
    /// URIごとの、走っている検索。同じ投稿を探しているときは、送り直さずに待つ。
    private var searches: [String: Task<Void, Never>] = [:]
    private lazy var interactions = StatusInteractions(operations: operations.interactions) { [weak self] id, transform in
        self?.update(id, transform)
    }
    /// そのアカウントと、そのサーバーでのIDの相手との関係。
    private let relationships: RelationshipCache
    /// そのアカウント自身のプロフィール。読めるまでnil。
    public private(set) var profile: Account?
    private var profileLoad: Task<Void, Never>?

    /// - Parameter tasks: 検索を始めるセッションの持ち主。ログアウトやアカウントの切り替えで止める。
    public init(credential: Credential, operations: Operations, tasks: TaskScope) {
        self.credential = credential
        self.operations = operations
        self.tasks = tasks
        let relationships = RelationshipCache(fetch: operations.relationships)
        self.relationships = relationships
        // キャッシュが自分で始めた通信も、セッションと一緒に止める。
        tasks.onClose { [weak relationships] in relationships?.close() }
    }

    /// そのアカウント自身のプロフィールを、まだ読んでいなければ読む。読めなければ、次に呼ばれたときに読み直す。
    public func loadProfile() {
        guard profile == nil, profileLoad == nil else { return }
        profileLoad = tasks.run(.display) { [weak self, operations] in
            let loaded = try? await operations.profile()
            self?.profile = loaded
            self?.profileLoad = nil
        }
    }

    /// そのアカウント自身のプロフィール。まだ読んでいなければ読み、読み終えるのを待つ。読めなければnil。
    public func loadedProfile() async -> Account? {
        loadProfile()
        await profileLoad?.value
        return profile
    }

    /// 覚えている、そのアカウントから見た`status`（ブーストなら元の投稿）。探していなければnil。
    public func known(_ status: Status) -> Status? {
        status.displayed.uri.flatMap { statuses[$0] }
    }

    /// そのアカウントのサーバーで、`status`（ブーストなら元の投稿）をURIで探す。見つけたら覚える。
    /// URIが同じ投稿だけを使う。検索はURIに近いほかの投稿を返すことがあり、違う投稿を操作しないため。
    /// 前に見つけた投稿を探せなかったときは、覚えている投稿を返す。
    public func lookup(_ status: Status) async -> Lookup {
        guard let uri = status.displayed.uri else { return .notFound }
        let search: Task<Void, Never>
        if let running = searches[uri] {
            search = running
        } else {
            let revision = revisions[uri, default: 0]
            guard let started = tasks.run(.action, { [weak self] in await self?.search(uri, since: revision) }) else {
                return .failed(CancellationError())
            }
            search = started
            searches[uri] = started
        }
        await search.value
        if searches[uri] == search {
            searches[uri] = nil
        }
        if let found = statuses[uri] { return .found(found) }
        if let failure = failures[uri] { return .failed(failure) }
        return .notFound
    }

    private func search(_ uri: String, since revision: Int) async {
        do {
            let results = try await operations.search(uri)
            failures[uri] = nil
            // 探している間に操作したら、探す前の状態の結果で、操作の結果を戻さない。
            guard revisions[uri, default: 0] == revision else { return }
            // 前に見つけた投稿も、見つからなければ、消されたり見られなくなったりしたので忘れる。
            statuses[uri] = results.map(\.displayed).first { $0.uri == uri }
        } catch {
            failures[uri] = error
        }
    }

    /// 前に見つけた`status`を探し直し、見つかった投稿でメニューに出る人の関係も読み直す。「別のアカウントで」を出したメニューを開くときに呼び、次に開いたときから使う。
    /// - Parameter relationIDs: 見つかった投稿で、関係の項目を出す人のID。組んだメニューの`otherAccountRelationIDs`を渡す。
    public func refresh(_ status: Status, relationIDs: @MainActor (_ found: Status, OtherAccount) -> [String]) async {
        guard case .found(let found) = await lookup(status) else { return }
        reloadRelations(relationIDs(found, self))
    }

    /// そのアカウントと`ids`の人の関係を、まとめて1回で読み直す。
    public func reloadRelations(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        relationships.reload(ids, purpose: .action)
    }

    /// そのアカウントとして、そのサーバーでのIDの相手へ関係の変更を送り、結果を覚える。
    public func change(_ change: UserRelationChange, of relation: UserRelation) async throws -> Relationship {
        let relationship = try await operations.changeRelation(change, relation.accountID)
        relationships[relation.accountID] = relationship
        return relationship
    }

    /// そのアカウントとしてのユーザーのメニューの、関係の項目を組むもの。
    /// 関係の項目のほか（メンション、コピー、メモ、通報、リストに追加）は、組む並びから除くので呼ばれない。押した変更は、メニューの命令として返す。
    public var userActions: UserMenuActions {
        UserMenuActions(
            mention: { _ in },
            copy: { _, _, _ in },
            localServer: credential.server,
            resolveTarget: { target in
                // 見つけた投稿の人だけを出すので、IDは分かっている。
                guard case .account(let id, let acct) = target else { throw CancellationError() }
                return UserIdentity(id: id, acct: acct)
            },
            loadRelation: { [weak self] _, identity in
                guard let self, let relationship = try await relationships.relationship(identity.id) else { return nil }
                return UserRelation(accountID: identity.id, acct: identity.acct, relationship: relationship)
            },
            knownRelation: { [weak self] target in
                guard let self, case .account(let id, let acct) = target else { return nil }
                let relation = relationships[id].map { UserRelation(accountID: id, acct: acct, relationship: $0) }
                guard id != credential.accountID else { return .myself(relation) }
                return relation.map { .relation($0) }
            },
            reloadRelations: { [weak self] ids in
                self?.relationships.reload(ids, purpose: .action)
            },
            changeRelation: { _, _ in },
            editNote: { _ in },
            report: { _, _, _ in },
            addToList: { _ in },
            accounts: accounts
        )
    }

    /// そのアカウントとして読む人。`UserMenuActions`が求めるので持つが、アイコンは今のアカウントで探すため使わない。
    private lazy var accounts = AccountCache { _ in [] }

    /// そのアカウントから見た投稿`status`の状態を反転する。同じ操作の結果を待っている間は何もせずfalseを返す。
    @discardableResult
    public func toggle(_ action: StatusInteractions.Action, on status: Status, reblogVisibility: ReblogVisibility = .accountDefault) async throws -> Bool {
        try await interactions.toggle(action, on: status, reblogVisibility: reblogVisibility)
    }

    private func update(_ id: Status.ID, _ transform: (Status) -> Status) {
        for (uri, status) in statuses where status.id == id {
            statuses[uri] = transform(status)
            revisions[uri, default: 0] += 1
        }
    }
}
