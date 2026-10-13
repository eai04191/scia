/// タイムラインの投稿を新しい順に持つ。RESTで読んだページと、ストリーミングで届いたイベントを合わせる。
@MainActor
public final class TimelineStore {
    public typealias Fetch = @Sendable (_ maxID: String?) async throws -> TimelinePage

    /// 新しい順。
    public private(set) var statuses: [Status] = []
    /// これより古い投稿はない。
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false
    /// 直近の読み込みで、サーバーがホームを再生成中だった。結果が揃っていないため、時間をおいて読み直す。
    public private(set) var isRegenerating = false
    /// ストリーミングで届き、まだ`statuses`に挿入していない投稿。届いた順。
    public private(set) var pending: [Status] = []
    /// 見た中で最も新しい投稿のID。これより新しい投稿を未読として数える。
    public private(set) var lastReadID: String?

    private let fetch: Fetch

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// 最新のページで置き換える。読み込み中なら何もせずnilを返す。
    public func loadInitial() async throws -> [Status]? {
        guard !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(nil)
        statuses = page.statuses
        isRegenerating = page.isRegenerating
        reachedEnd = page.statuses.isEmpty && !page.isRegenerating
        return statuses
    }

    /// 末尾より古いページを読み、新たに足した投稿を返す。
    /// 読み込み中、終端に達している、まだ1件もない場合は何もせずnilを返す。
    public func loadOlder() async throws -> [Status]? {
        guard !isLoading, !reachedEnd, let oldest = statuses.last else { return nil }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(oldest.id)
        isRegenerating = page.isRegenerating
        let known = Set(statuses.map(\.id))
        let added = page.statuses.filter { !known.contains($0.id) }
        statuses.append(contentsOf: added)
        if page.statuses.isEmpty && !page.isRegenerating {
            reachedEnd = true
        }
        return added
    }

    // MARK: - ストリーミング

    /// イベントを反映した結果。
    public enum EventResult: Equatable, Sendable {
        /// 表示に関わる変化はない。
        case none
        /// 保留が空のところへ新着が届いた。挿入の時機をはかり始める。
        case pendingStarted
        /// `statuses`が変わった。
        case statusesChanged
    }

    /// 新着は保留に溜め、編集と削除はすぐ反映する。
    public func receive(_ event: StreamingEvent) -> EventResult {
        switch event {
        case .update(let status):
            guard !statuses.contains(where: { $0.id == status.id }), !pending.contains(where: { $0.id == status.id }) else {
                return .none
            }
            pending.append(status)
            return pending.count == 1 ? .pendingStarted : .none
        case .statusUpdate(let edited):
            pending = pending.map { Self.replacing(edited, in: $0) }
            let replaced = statuses.map { Self.replacing(edited, in: $0) }
            guard replaced != statuses else { return .none }
            statuses = replaced
            return .statusesChanged
        case .delete(let id):
            // 元の投稿が消えると、それをブーストした投稿も表示できなくなる。
            pending.removeAll { $0.id == id || $0.reblog?.id == id }
            let remaining = statuses.filter { $0.id != id && $0.reblog?.id != id }
            guard remaining.count != statuses.count else { return .none }
            statuses = remaining
            return .statusesChanged
        case .filtersChanged, .unhandled:
            return .none
        }
    }

    /// 保留していた投稿をIDの順に合流させ、新たに加わった投稿を新しい順に返す。
    ///
    /// 読み込んだ末尾より古い投稿は捨てる。末尾に足すと、次に古いページを読むときの`max_id`がずれて、間の投稿を読み飛ばすため。
    public func flushPending() -> [Status] {
        defer { pending.removeAll() }
        let known = Set(statuses.map(\.id))
        var added = Dictionary(pending.filter { !known.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        if !reachedEnd, let oldest = statuses.last {
            added = added.filter { StatusID.isNewer($0.key, than: oldest.id) }
        }
        guard !added.isEmpty else { return [] }
        statuses = (statuses + added.values).sorted { StatusID.isNewer($0.id, than: $1.id) }
        return added.values.sorted { StatusID.isNewer($0.id, than: $1.id) }
    }

    // MARK: - 未読

    /// 画面に表示された投稿を既読にする。既読の位置は新しい方へだけ進む。
    public func markRead(_ ids: some Sequence<String>) {
        guard let newest = ids.max(by: { StatusID.isNewer($1, than: $0) }) else { return }
        if let lastReadID, !StatusID.isNewer(newest, than: lastReadID) { return }
        lastReadID = newest
    }

    /// 既読の位置より新しい、挿入済みの投稿の数。既読の位置が決まっていなければ0。
    public var unreadCount: Int {
        guard let lastReadID else { return 0 }
        return statuses.prefix { StatusID.isNewer($0.id, than: lastReadID) }.count
    }

    private static func replacing(_ edited: Status, in status: Status) -> Status {
        if status.id == edited.id { return edited }
        if status.reblog?.id == edited.id { return status.replacingReblog(with: edited) }
        return status
    }
}
