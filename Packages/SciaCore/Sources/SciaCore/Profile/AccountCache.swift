import Foundation
import os

/// ログイン中のセッションで読んだアカウント。メンションのように、IDしか分からない相手のアイコンを出すのに使う。
///
/// 足りないアカウントは、相手ごとにリクエストを送らず、`MastodonClient.multipleAccountsLimit`件ずつまとめて1回で読む。
/// メンションが何人いても、メニューを開くたびのリクエストは1回で済み、トークンごとのレート制限を削らない。
/// IDはサーバーごとに違うため、セッション（ログイン中のアカウント）ごとに持つ。起動している間だけ覚え、相手がプロフィールを変えても追わない。
@MainActor
public final class AccountCache {
    public typealias Fetch = @Sendable ([String]) async throws -> [Account]

    private let fetch: Fetch
    private let limit: Int
    private var accounts: [String: Account] = [:]
    /// 読み込み中のIDと、それを読んでいる読み込み。同じIDを続けて求められても、二重に送らない。
    private var inFlight: [String: Task<Void, Never>] = [:]
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

    /// `ids`のアカウントを読み、読めたものを返す。読み込み済みのものは読まず、読み込み中のものはその読み込みを待つ。
    /// 読めなかったアカウント（見つからない、承認されていない、リクエストが失敗した）は返さず、覚えもしないので、次に求められたときに読み直す。
    public func load(_ ids: [String]) async -> [String: Account] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let missing = unique.filter { accounts[$0] == nil && inFlight[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: limit) {
            let chunk = Array(missing[start..<min(start + limit, missing.count)])
            let task = Task {
                do {
                    for account in try await fetch(chunk) {
                        accounts[account.id] = account
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
}
