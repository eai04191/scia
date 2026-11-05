/// 投稿のメニューの「別のアカウントで」で、ログインしているほかのアカウント1つとして投稿を操作する。決まりはdocs/menus.mdにある。
///
/// 投稿のIDはサーバーごとに違うため、そのアカウントのサーバーで、投稿のURIを探して引き直す。見つけた投稿はURIごとに覚え、
/// 操作の結果もその投稿に反映する。今のアカウントの一覧の投稿は変えない。
@MainActor
public final class OtherAccountStatuses {
    /// APIを呼ぶ口。テストでは差し替える。
    public struct Operations: Sendable {
        /// `resolve=true`で投稿を探す。
        public var search: @Sendable (String) async throws -> [Status]
        public var interactions: StatusInteractions.Operations

        public init(search: @escaping @Sendable (String) async throws -> [Status], interactions: StatusInteractions.Operations) {
            self.search = search
            self.interactions = interactions
        }

        public init(client: MastodonClient) {
            self.init(
                search: { try await client.search($0, category: .statuses, resolve: true, limit: 5).statuses },
                interactions: StatusInteractions.Operations(client: client)
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

    /// - Parameter tasks: 検索を始めるセッションの持ち主。ログアウトやアカウントの切り替えで止める。
    public init(credential: Credential, operations: Operations, tasks: TaskScope) {
        self.credential = credential
        self.operations = operations
        self.tasks = tasks
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
