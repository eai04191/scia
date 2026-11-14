public import Foundation
import os

/// ログイン中のセッションで読んだアカウント。メンションのように、IDしか分からない相手のアイコンを出すのに使う。
/// プロフィールのURLやハンドルで探したアカウントも、探した値ごとに覚える。探すのは検索のAPIで、相手のサーバーへの問い合わせも起きるため、同じ相手を何度も探さない。
///
/// 足りないアカウントは、相手ごとにリクエストを送らず、`MastodonClient.multipleAccountsLimit`件ずつまとめて1回で読む。
/// メンションが何人いても、メニューを開くたびのリクエストは1回で済み、トークンごとのレート制限を削らない。
/// IDはサーバーごとに違うため、セッション（ログイン中のアカウント）ごとに持つ。起動している間だけ覚える。
/// 覚えたアカウントを置き換えるのは、プロフィール画面が読んだものだけで、ほかに相手がプロフィールを変えても追わない。
@MainActor
public final class AccountCache {
    public typealias Fetch = @Sendable ([String]) async throws -> [Account]

    private let fetch: Fetch
    private let limit: Int
    private var accounts: [String: Account] = [:]
    /// プロフィール画面が読んだアカウント。`accounts`と分けて持ち、ほかの読み込みや検索の応答では置き換えない。プロフィール画面が読む前に始めた読み込みの応答が、あとから届くことがあるため。
    private var profiles: [String: Account] = [:]
    /// 読み込み中のIDと、それを読んでいる読み込み。同じIDを続けて求められても、二重に送らない。
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// 探して見つかったアカウントのID。
    private var resolvedIDs: [AccountLookup: String] = [:]
    /// 探している途中の値と、その検索。同じ値を続けて探しても、二重に送らない。
    private var resolving: [AccountLookup: Task<Account?, any Error>] = [:]
    private var isClosed = false
    private let logger = SciaLog.logger(category: "accountCache")

    /// - Parameter limit: 1回のリクエストで読む数。
    public init(limit: Int = MastodonClient.multipleAccountsLimit, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.limit = limit
    }

    /// 読み込み済みのアカウント。読んでいなければnil。
    public func account(_ id: String) -> Account? {
        accounts[id]
    }

    /// プロフィール画面を`account`で開くときに、最初に出すアカウント。前にプロフィール画面が読んでいればそれを、なければ`account`を返す。
    /// 開くときに渡るアカウントは、投稿に付いてきたものや、前に探して覚えたもので、プロフィール画面が読んだものより古いことがあるため。
    /// アイコンのために読んだだけのアカウントは、渡されたものより新しいとは限らないので使わない。
    public func profile(startingFrom account: Account) -> Account {
        profiles[account.id] ?? account
    }

    /// プロフィール画面が読んだか、編集して保存した`account`を覚える。IDで読む経路と探して開く経路も、次からこれを返す。
    public func rememberProfile(_ account: Account) {
        profiles[account.id] = account
        accounts[account.id] = account
    }

    /// 読み込みや検索で届いた`account`を覚える。プロフィール画面が読んだものがあれば、そちらを残す。
    private func remember(_ account: Account) {
        accounts[account.id] = profiles[account.id] ?? account
    }

    /// `ids`のアカウントを読み、読めたものを返す。読み込み済みのものは読まず、読み込み中のものはその読み込みを待つ。
    /// 読めなかったアカウント（見つからない、承認されていない、リクエストが失敗した）は返さず、覚えもしないので、次に求められたときに読み直す。
    public func load(_ ids: [String]) async -> [String: Account] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let missing = isClosed ? [] : unique.filter { accounts[$0] == nil && inFlight[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: limit) {
            let chunk = Array(missing[start..<min(start + limit, missing.count)])
            let task = Task {
                do {
                    for account in try await fetch(chunk) {
                        remember(account)
                    }
                } catch {
                    logger.error("accounts load failed count=\(chunk.count, privacy: .public): \(SciaLog.describe(error), privacy: .public)")
                }
                for id in chunk {
                    inFlight[id] = nil
                }
            }
            for id in chunk {
                inFlight[id] = task
            }
        }
        for task in Set(unique.compactMap { inFlight[$0] }) {
            await task.value
        }
        return unique.reduce(into: [:]) { loaded, id in
            loaded[id] = accounts[id]
        }
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
        if let id = resolvedIDs[lookup], let account = accounts[id] {
            return account
        }
        if let task = resolving[lookup] {
            return try await task.value
        }
        guard !isClosed else { throw CancellationError() }
        let task = Task { try await search() }
        resolving[lookup] = task
        defer { resolving[lookup] = nil }
        let account = try await task.value
        if let account {
            remember(account)
            resolvedIDs[lookup] = account.id
        }
        return account
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
