import Synchronization

/// REST APIの応答とストリーミングで受け取ったアカウントの、IDごとに一番新しいもの。
/// 投稿の投稿者、ブーストした人、通知を送った人、人のリスト、プロフィールなど、応答の中のどこにあるアカウントも、読んだときにその場で覚える。
/// 応答を受け取った側が続けて読むときには、もう覚え終えている。
///
/// アカウントには更新日時がないので、どれが新しいかは番号の順で決める。番号は、読み込みなら送る前に、書き込みなら応答を受け取ったときにとる。
/// 先に読み始めた読み込みの応答が遅れて届いても、あとからとった番号のものを戻さない。書き込みの応答は、書き込みが済む前に読み始めた読み込みより新しい。
public final class ReceivedAccounts: Sendable {
    private struct State {
        var count = 0
        var accounts: [String: Account] = [:]
        /// IDごとに、覚えているアカウントの番号。
        var orders: [String: Int] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// 番号をとる。読み込みなら送る前に、書き込みなら応答を受け取ったときに呼ぶ。
    public func nextOrder() -> Int {
        state.withLock { state in
            state.count += 1
            return state.count
        }
    }

    /// 覚えているアカウント。受け取っていなければnil。
    public func account(_ id: String) -> Account? {
        state.withLock { $0.accounts[id] }
    }

    /// `order`の番号で受け取った`accounts`を覚える。同じ人をもっとあとの番号で覚えていれば、そちらを残す。
    /// 同じ番号は同じ応答なので、あとに読んだほうで置き換える。
    public func remember(_ accounts: [Account], order: Int) {
        guard !accounts.isEmpty else { return }
        state.withLock { state in
            for account in accounts where state.orders[account.id].map({ $0 <= order }) ?? true {
                state.accounts[account.id] = account
                state.orders[account.id] = order
            }
        }
    }

    /// `decode`の中で読んだアカウントを、`order`の番号で覚える。
    func collect<T>(order: Int, _ decode: () throws -> T) rethrows -> T {
        let collector = Collector()
        let value = try Self.$collector.withValue(collector) { try decode() }
        remember(collector.accounts, order: order)
        return value
    }

    /// 読み終えたアカウントを、読んでいる応答の集める先に足す。集めていなければ何もしない。
    static func record(_ account: Account) {
        collector?.append(account)
    }

    @TaskLocal private static var collector: Collector?

    private final class Collector: Sendable {
        private let storage = Mutex<[Account]>([])

        var accounts: [Account] { storage.withLock { $0 } }

        func append(_ account: Account) {
            storage.withLock { $0.append(account) }
        }
    }
}
