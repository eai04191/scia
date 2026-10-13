/// タイムラインを新しい順に読み込み、下方向へ古い投稿を足していく。
@MainActor
public final class TimelinePager {
    public typealias Fetch = @Sendable (_ maxID: String?) async throws -> TimelinePage

    /// 新しい順。
    public private(set) var statuses: [Status] = []
    /// これより古い投稿はない。
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false

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
        let known = Set(statuses.map(\.id))
        let added = page.statuses.filter { !known.contains($0.id) }
        statuses.append(contentsOf: added)
        if page.statuses.isEmpty && !page.isRegenerating {
            reachedEnd = true
        }
        return added
    }
}
