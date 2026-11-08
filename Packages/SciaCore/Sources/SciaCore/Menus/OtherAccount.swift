public import Foundation

/// 投稿のメニューの「別のアカウントで」で、ログインしているほかのアカウント1つとして、投稿と、投稿に出る人を操作する。決まりはdocs/other-accounts.mdにある。
///
/// 投稿のIDはサーバーごとに違うため、そのアカウントのサーバーで、投稿のURIを探して引き直す。見つけた投稿はURIごとに覚え、
/// 操作の結果もその投稿に反映する。人は、見つけた投稿の投稿者とメンションの、そのサーバーでのIDで扱い、関係はこのアカウントで覚える。
/// 今のアカウントのタイムラインの投稿や、覚えている関係は変えない。
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
        /// プロフィールのURLで人を探す。そのサーバーが知らない人も、相手のサーバーに問い合わせて探す。見つからなければnil。
        public var resolveAccount: @Sendable (URL) async throws -> Account?
        /// そのアカウントの投稿を、添付ごと削除する。
        public var deleteStatus: @Sendable (Status.ID) async throws -> Void
        /// そのアカウントのサーバーの、Mastodonにない機能の有無。絵文字のリアクションを出すかに使う。
        public var capabilities: @Sendable () async throws -> ServerCapabilities

        public init(
            search: @escaping @Sendable (String) async throws -> [Status],
            interactions: StatusInteractions.Operations,
            profile: @escaping @Sendable () async throws -> Account,
            relationships: @escaping RelationshipCache.Fetch,
            changeRelation: @escaping @Sendable (UserRelationChange, String) async throws -> Relationship,
            resolveAccount: @escaping @Sendable (URL) async throws -> Account?,
            deleteStatus: @escaping @Sendable (Status.ID) async throws -> Void,
            capabilities: @escaping @Sendable () async throws -> ServerCapabilities
        ) {
            self.search = search
            self.interactions = interactions
            self.profile = profile
            self.relationships = relationships
            self.changeRelation = changeRelation
            self.resolveAccount = resolveAccount
            self.deleteStatus = deleteStatus
            self.capabilities = capabilities
        }

        public init(client: MastodonClient) {
            let accountID = client.credential.accountID
            self.init(
                search: { try await client.search($0, category: .statuses, resolve: true, limit: 5).statuses },
                interactions: StatusInteractions.Operations(client: client),
                profile: { try await client.account(accountID) },
                relationships: { try await client.relationships($0) },
                changeRelation: { try await client.send($0, to: $1) },
                resolveAccount: { try await client.resolveAccount(at: $0) },
                // web UIと同じく、添付もすぐ消す。今のアカウントで削除するときと同じ。
                deleteStatus: { try await client.deleteStatus($0, deleteMedia: true) },
                capabilities: { try await client.serverCapabilities() }
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
    /// プロフィールのURLごとの、そのサーバーで見つけた人。見つからなかった人は入れない。
    private var people: [URL: Account] = [:]
    /// 探せたが見つからなかった人のプロフィールのURL。開いたメニューで探すのを待たないために使う。探し直しは続け、見つかったら除く。
    private var peopleNotFound: Set<URL> = []
    /// プロフィールのURLごとの、最後に探せなかった理由。探せたら消す。
    private var peopleFailures: [URL: any Error] = [:]
    /// プロフィールのURLごとの、走っている人の検索。同じ人を探しているときは、送り直さずに待つ。
    private var peopleSearches: [URL: Task<Void, Never>] = [:]
    /// そのアカウントのハッシュタグのフォロー、ミュート、プロフィールでの紹介を読んで変えるもの。nilなら、それらの項目を出さない。
    /// そのアカウントのクライアントで読むハッシュタグのリストが要るので、アプリが作って入れる。
    public var hashtagActions: HashtagMenuActions?
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

    /// そのアカウントのサーバーが、絵文字のリアクションに対応しているか。読めないうちと、読めなかったときはfalse（docs/emoji-reaction.md）。
    public private(set) var supportsEmojiReactions = false
    private var capabilitiesState = CapabilitiesState.unknown
    private enum CapabilitiesState { case unknown, loading, loaded }
    /// サーバーの機能の有無を読んでいる途中か。
    public var isLoadingCapabilities: Bool { capabilitiesState == .loading }

    /// そのアカウントのサーバーの機能の有無を読む。読めたら読み直さず、読めなかったら次に呼ばれたときに読み直す。
    public func loadCapabilities() {
        guard capabilitiesState == .unknown else { return }
        capabilitiesState = .loading
        tasks.run(.display) { [weak self, operations] in
            let loaded = try? await operations.capabilities()
            guard let self else { return }
            if let loaded {
                supportsEmojiReactions = loaded.supportsEmojiReactions
                capabilitiesState = .loaded
            } else {
                capabilitiesState = .unknown
            }
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
    /// - Parameters:
    ///   - people: 投稿のほかにメニューに出る人（ブーストした人、通知した人）。まだ見つけていない人を探す。
    ///   - relationIDs: 見つかった投稿で、関係の項目を出す人のID。組んだメニューの`otherAccountRelationIDs`を渡す。
    public func refresh(_ status: Status, people: [Account], relationIDs: @MainActor (_ found: Status, OtherAccount) -> [String]) async {
        async let lookedUp = lookup(status)
        await resolve(people)
        guard case .found(let found) = await lookedUp else { return }
        reloadRelations(relationIDs(found, self))
    }

    /// 覚えている、そのサーバーで見つけた`account`と同じ人。プロフィールのURLで探す。まだ探していないか、見つからなければnil。
    public func person(_ account: Account) -> Account? {
        account.url.flatMap(person(at:))
    }

    /// 覚えている、そのサーバーで見つけた、プロフィールのURLが`url`の人。まだ探していないか、見つからなければnil。
    public func person(at url: URL) -> Account? {
        people[url]
    }

    /// そのアカウントで人を探した結果。
    public enum PersonLookup: Sendable {
        /// そのサーバーでの、その人。
        case found(Account)
        /// 探せたが、そのサーバーでは見つからない。
        case notFound
        /// 探せなかった。
        case failed(any Error)
    }

    /// そのアカウントのサーバーで、プロフィールのURLが`url`の人を探す。見つけた人は覚え、覚えていればそのまま返す。
    /// ユーザーのメニューの「別のアカウントで」で使う。
    public func lookUpPerson(at url: URL) async -> PersonLookup {
        await resolve(urls: [url])
        if let found = people[url] { return .found(found) }
        if let failure = peopleFailures[url] { return .failed(failure) }
        return .notFound
    }

    /// `account`を、まだそのサーバーで探していないか。探せなかった人も含む。見つからなかった人は含まない。
    public func needsResolving(_ account: Account) -> Bool {
        guard let url = account.url else { return false }
        return people[url] == nil && !peopleNotFound.contains(url)
    }

    /// `accounts`のうちまだ見つけていない人を、そのサーバーでプロフィールのURLで探して覚える。
    /// 人のIDはサーバーごとに違い、見つけた投稿には投稿者とメンションのほかの人のIDが入っていないため。
    /// URLが同じ人だけを使う。違う人を操作しないため。見つからない、探せない人は、次に呼ばれたときに探し直す。
    public func resolve(_ accounts: [Account]) async {
        await resolve(urls: Set(accounts.compactMap(\.url)))
    }

    private func resolve(urls: Set<URL>) async {
        let urls = urls.filter { people[$0] == nil }
        let searches = urls.compactMap { url -> Task<Void, Never>? in
            if let running = peopleSearches[url] { return running }
            // 始めた検索は、このあとの代入を終えてから走るので、走り終えたときに自分で除ける。
            let started = tasks.run(.action) { [weak self, operations] in
                defer { self?.peopleSearches[url] = nil }
                let resolved: Account?
                do {
                    resolved = try await operations.resolveAccount(url)
                } catch {
                    // 探せなかったときは、見つからなかったとは決めずに、次に開いたメニューでも待って探す。
                    self?.peopleFailures[url] = error
                    return
                }
                self?.peopleFailures[url] = nil
                if let found = resolved, found.url == url {
                    self?.people[url] = found
                    self?.peopleNotFound.remove(url)
                } else {
                    self?.peopleNotFound.insert(url)
                }
            }
            peopleSearches[url] = started
            return started
        }
        for running in searches {
            await running.value
        }
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

    /// そのアカウントのシート（メモ、リストに追加）で変わった関係を覚える。次に開いたメニューの項目に出す。
    public func didChange(_ relationship: Relationship) {
        relationships[relationship.id] = relationship
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

    /// そのアカウントとして、`status`に`emoji`でリアクションする。すでに付けている絵文字なら、付けたままにする（docs/emoji-reaction.md）。
    /// - Returns: 送ったか。同じ操作の結果を待っている間はfalse。
    public func react(with emoji: ReactionEmoji, on status: Status) async throws -> Bool {
        try await interactions.set(.emojiReaction(emoji), to: true, on: status)
    }

    /// そのアカウントの投稿`status`を削除し、覚えている投稿からも除く。
    public func delete(_ status: Status) async throws {
        try await operations.deleteStatus(status.id)
        didDelete(status.id)
    }

    /// そのアカウントの投稿が消えたので、覚えている投稿から除く。削除して書き直す元の投稿を投稿欄が消したときにも呼ぶ。
    /// 探している途中の検索の結果で、消えた投稿を戻さない。
    public func didDelete(_ id: Status.ID) {
        for (uri, known) in statuses where known.id == id {
            statuses[uri] = nil
            revisions[uri, default: 0] += 1
        }
    }

    /// そのアカウントで編集した投稿を、サーバーが返した編集のあとの投稿で覚え直す。
    /// 次に開いたメニューの編集を、編集の前の添付で始めず、探している途中の検索の結果でも戻さない。
    public func didEdit(_ edited: Status) {
        update(edited.id) { _ in edited }
    }

    private func update(_ id: Status.ID, _ transform: (Status) -> Status) {
        for (uri, status) in statuses where status.id == id {
            statuses[uri] = transform(status)
            revisions[uri, default: 0] += 1
        }
    }
}

// MARK: - メニュー

extension OtherAccount {
    /// 「別のアカウントで」のサブメニュー。ほかのアカウントが1つなら「@usernameで」を直に置き、2つ以上なら`title`の中にアカウントごとの`@username`のサブメニューを並べる。ほかのアカウントがなければnil。
    /// サーバー名は、ユーザーのメニューの見出しと同じくサブタイトルに出す。名前に`@username@server`をそのまま置くと、長いサーバー名で途中から折り返されて読みにくいため。
    /// アカウントの行には、そのアカウント自身のアイコンを付ける。
    /// - Parameter children: そのアカウントとしての中身。
    static func accountsMenu<Command>(_ accounts: [OtherAccount], title: String, symbolName: String, children: (OtherAccount) -> [MenuNode<Command>]) -> MenuNode<Command>? {
        guard !accounts.isEmpty else { return nil }
        if accounts.count == 1, let account = accounts.first {
            let credential = account.credential
            return .submenu("@\(credential.username)で", subtitle: credential.server, icon: .avatar(.otherAccount(account), fallbackSymbol: symbolName), children(account))
        }
        return .submenu(title, icon: .symbol(symbolName), accounts.map { account in
            let credential = account.credential
            return .submenu("@\(credential.username)", subtitle: credential.server, icon: .avatar(.otherAccount(account), fallbackSymbol: "person.crop.circle"), children(account))
        })
    }

    /// そのアカウントのサーバーで探せなかったことを、理由を添えて出す押せない行。
    /// メニューの行には理由の文字しか置けないので、ログアウトされていれば、ログインし直す項目を続けて置く。失敗の理由を出す部品と同じく、どこで失敗してもその場でログインし直せるようにするため。
    static func lookupFailureNodes<Command>(title: String, error: any Error, logIn: (RequestAccount) -> Command) -> [MenuNode<Command>] {
        let reason = ErrorPresentation(error)
        let logInNode = reason.loggedOutAccount.map { [MenuNode<Command>.action("ログインし直す", icon: .symbol("person.crop.circle.badge.exclamationmark"), logIn($0))] } ?? []
        return [.action(title, subtitle: reason.text, nil)] + logInNode
    }
}

/// 「別のアカウントで」の、ほかのアカウントとしての人への操作。相手のIDと`acct`は、そのアカウントのサーバーのもの。
public enum OtherAccountUserAction: Sendable {
    /// 関係の変更。
    case relation(UserRelationChange, UserRelation)
    /// 自分にしか見えないメモのシートを開く。
    case note(UserRelation)
    /// 通報のシートを開く。添える投稿のIDも、そのアカウントのサーバーのもの。
    case report(accountID: String, acct: String, statusID: String?)
    /// そのアカウントのリストに入れるシートを開く。
    case addToList(accountID: String, acct: String)
    /// 投稿欄をそのアカウントに切り替えて、`@acct`を入れる。
    case mention(acct: String)

    /// そのアカウントとして組んだユーザーのメニューの命令を、ほかのアカウントとしての操作にする。ほかのアカウントでは行わない命令はnil。
    /// - Parameters:
    ///   - id: メニューを組んだ相手の、そのアカウントのサーバーでのID。
    ///   - acct: メニューを組んだ相手の、そのアカウントのサーバーから見た`acct`。
    init?(_ command: UserMenuCommand, id: String, acct: String) {
        switch command {
        case .changeRelation(let change, let relation): self = .relation(change, relation)
        case .editNote(let relation): self = .note(relation)
        case .report(let accountID, let acct, let statusID): self = .report(accountID: accountID, acct: acct, statusID: statusID)
        case .addToList: self = .addToList(accountID: id, acct: acct)
        case .mention: self = .mention(acct: acct)
        // 「別のアカウントで」の中には、どのアカウントでも同じ結果になる項目を組まない。
        case .url, .openProfile, .copy, .otherAccount, .logIn, .customize: return nil
        }
    }
}
