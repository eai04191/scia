public import Foundation
import os

/// ログイン中のセッションで受け取ったアカウントの、IDごとに一番新しいもの。
/// メンションのように、IDしか分からない相手のアイコンを出すのと、プロフィール画面を開くときに最初に出すのに使う。
/// プロフィールのURLやハンドルで探したアカウントも、探した値ごとに覚える。探すのは検索のAPIで、相手のサーバーへの問い合わせも起きるため、同じ相手を何度も探さない。
///
/// 覚えるのは`ReceivedAccounts`で、自分で読んだものに加え、タイムラインの投稿や通知、プロフィールなど、セッションのクライアントとストリーミングが受け取ったアカウントをすべて覚える。
/// 新しいものを決める番号の決まりは`ReceivedAccounts`にある。
///
/// 足りないアカウントは、相手ごとにリクエストを送らず、`MastodonClient.multipleAccountsLimit`件ずつまとめて1回で読む。
/// メンションが何人いても、メニューを開くたびのリクエストは1回で済み、トークンごとのレート制限を削らない。
/// IDはサーバーごとに違うため、セッション（ログイン中のアカウント）ごとに持つ。起動している間だけ覚え、覚える人数の上限は`ReceivedAccounts.limit`。
@MainActor
public final class AccountCache {
    public typealias Fetch = @Sendable ([String]) async throws -> [Account]

    private let fetch: Fetch
    private let limit: Int
    /// 覚えているアカウント。セッションのクライアントとストリーミングと共有する。
    private let received: ReceivedAccounts
    /// 読み込み中のIDと、それを読んでいる読み込み。同じIDを続けて求められても、二重に送らない。読み込みは読めたアカウントを返す。
    private var inFlight: [String: Task<[Account], Never>] = [:]
    /// 探して見つかったアカウントのID。
    private var resolvedIDs: [AccountLookup: String] = [:]
    /// 探している途中の値と、その検索。同じ値を続けて探しても、二重に送らない。
    private var resolving: [AccountLookup: Task<Account?, any Error>] = [:]
    private var isClosed = false
    private let logger = SciaLog.logger(category: "accountCache")

    /// - Parameters:
    ///   - limit: 1回のリクエストで読む数。
    ///   - received: 覚える先。セッションのクライアントとストリーミングに渡したものと同じものを渡す。
    public init(limit: Int = MastodonClient.multipleAccountsLimit, received: ReceivedAccounts = ReceivedAccounts(), fetch: @escaping Fetch) {
        self.fetch = fetch
        self.limit = limit
        self.received = received
    }

    /// 覚えているアカウント。受け取っていなければnil。
    public func account(_ id: String) -> Account? {
        received.account(id)
    }

    public func account(acct: String, localDomain: String?) -> Account? {
        received.account(acct: acct, localDomain: localDomain)
    }

    /// `account`と同じ人の、覚えている一番新しいアカウント。覚えていなければ`account`を返す。
    /// プロフィール画面を開くときに渡るアカウントは、前に受け取った投稿に付いてきたものなどで、そのあとに受け取ったものより古いことがあるため、これで出す。
    public func latest(of account: Account) -> Account {
        received.account(account.id) ?? account
    }

    /// `ids`のアカウントを読み、読めたものを返す。読み込み済みのものは読まず、読み込み中のものはその読み込みを待つ。
    /// 読めなかったアカウント（見つからない、承認されていない、リクエストが失敗した）は返さず、覚えもしないので、次に求められたときに読み直す。
    public func load(_ ids: [String]) async -> [String: Account] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        // 待つ間に、ほかの経路で受け取った人で上限を超えて消えても返せるよう、覚えていた人と読めた人を手元にも持つ。
        var loaded: [String: Account] = unique.reduce(into: [:]) { loaded, id in
            loaded[id] = received.account(id)
        }
        let missing = isClosed ? [] : unique.filter { loaded[$0] == nil && inFlight[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: limit) {
            let chunk = Array(missing[start..<min(start + limit, missing.count)])
            let order = received.nextOrder()
            let task = Task {
                var accounts: [Account] = []
                do {
                    accounts = try await fetch(chunk)
                    received.remember(accounts, order: order)
                } catch {
                    logger.error("accounts load failed count=\(chunk.count, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
                }
                for id in chunk {
                    inFlight[id] = nil
                }
                return accounts
            }
            for id in chunk {
                inFlight[id] = task
            }
        }
        for task in Set(unique.compactMap { inFlight[$0] }) {
            for account in await task.value where seen.contains(account.id) {
                loaded[account.id] = account
            }
        }
        // 待つ間に、もっと新しいものを受け取っていれば、そちらを返す。
        return loaded.mapValues(latest(of:))
    }

    /// 走っている読み込みと検索を止め、以後は読まない。ログアウトやアカウントの切り替えのあとに、前のアカウントのトークンで通信し続けないため。
    public func close() {
        isClosed = true
        for task in Set(inFlight.values) {
            task.cancel()
        }
        for task in resolving.values {
            task.cancel()
        }
    }

    /// 文字のままのハンドル`handle`（`user@domain`）の人を探す。覚えている人も含め、書かれたハンドルと同じ人だけを返す。ほかの経路が同じハンドルで覚えた、似た名前の人を受け取らないため。
    public func resolve(handle: String, localServer: String, search: @escaping @Sendable () async throws -> Account?) async throws -> Account? {
        guard let account = try await resolve(.acct(handle), search: search), account.hasHandle(handle, localServer: localServer) else { return nil }
        return account
    }

    /// `lookup`で探したアカウント。前に見つけていればそれを返し、探している途中ならその検索を待ち、どちらでもなければ`search`で探す。
    /// 見つからなかったときと、検索が失敗したときは覚えず、次に求められたときに探し直す。
    public func resolve(_ lookup: AccountLookup, search: @escaping @Sendable () async throws -> Account?) async throws -> Account? {
        let lookup = lookup.normalized
        if let id = resolvedIDs[lookup], let account = received.account(id) {
            return account
        }
        if let task = resolving[lookup] {
            return try await task.value.map(latest(of:))
        }
        guard !isClosed else { throw CancellationError() }
        let order = received.nextOrder()
        let task = Task { try await search() }
        resolving[lookup] = task
        defer { resolving[lookup] = nil }
        guard let account = try await task.value else { return nil }
        received.remember([account], order: order)
        resolvedIDs[lookup] = account.id
        // 探している間に、もっと新しいものを受け取っていれば、そちらを返す。
        return latest(of: account)
    }
}

/// アカウントを探す値。
public enum AccountLookup: Hashable, Sendable {
    /// プロフィールのページのURL。本文や自己紹介のメンションのリンク。
    case profileURL(URL)
    /// `user@domain`の形のハンドル。大文字と小文字を区別しない。
    case acct(String)

    /// 同じ相手を同じ値として覚えるため、ハンドルは小文字にそろえる。
    var normalized: AccountLookup {
        switch self {
        case .profileURL: self
        case .acct(let acct): .acct(acct.lowercased())
        }
    }
}
