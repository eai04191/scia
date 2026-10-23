import Foundation

/// 人の一覧（お気に入りした人、ブーストした人、フォロワー、フォロー）を、サーバーが返す順に持つ。
/// 続きは、応答の`Link`ヘッダーの`next`にある`max_id`から読む。
@MainActor
public final class AccountListStore {
    public typealias Fetch = @Sendable (_ maxID: String?) async throws -> AccountListPage

    public let kind: AccountListKind
    /// サーバーが返す順。同じ人は1度だけ並べる。
    public private(set) var accounts: [Account] = []
    /// これより後ろはない。
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false
    private var nextMaxID: String?
    private let fetch: Fetch

    public init(kind: AccountListKind, fetch: @escaping Fetch) {
        self.kind = kind
        self.fetch = fetch
    }

    /// 最初のページで置き換える。読み込み中なら何もせずnilを返す。
    public func loadInitial() async throws -> [Account]? {
        guard !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(nil)
        accounts = []
        return apply(page, after: nil)
    }

    /// 続きのページを読み、新たに足した人を返す。読み込み中か、終わりに着いていれば何もせずnilを返す。
    public func loadOlder() async throws -> [Account]? {
        guard !isLoading, !reachedEnd, let maxID = nextMaxID else { return nil }
        isLoading = true
        defer { isLoading = false }

        return apply(try await fetch(maxID), after: maxID)
    }

    /// 同じ位置を返し続けるサーバーで同じページを読み続けないよう、続きの位置が進まなければ終わりにする。
    private func apply(_ page: AccountListPage, after maxID: String?) -> [Account] {
        let known = Set(accounts.map(\.id))
        var seen = known
        let added = page.accounts.filter { seen.insert($0.id).inserted }
        accounts += added
        nextMaxID = page.nextMaxID
        reachedEnd = page.nextMaxID == nil || page.nextMaxID == maxID || page.accounts.isEmpty
        return added
    }
}
