import MemoryCache
import Synchronization

/// REST APIの応答とストリーミングで受け取ったアカウントの、IDごとに一番新しいもの。
/// 投稿の投稿者、ブーストした人、通知を送った人、人のリスト、プロフィールなど、応答の中のどこにあるアカウントも、読んだときにその場で覚える。
/// 応答を受け取った側が続けて読むときには、もう覚え終えている。
///
/// アカウントには更新日時がないので、どれが新しいかは番号の順で決める。番号は、読み込みなら送る前に、書き込みなら応答を受け取ったときにとる。
/// 先に読み始めた読み込みの応答が遅れて届いても、あとからとった番号のものを戻さない。書き込みの応答は、書き込みが済む前に読み始めた読み込みより新しい。
///
/// 覚えるのは`limit`人までで、超えたら、受け取ったり読んだりしてから一番長い人から消す。消した人は、次に受け取るまで覚えていない。
/// 番号もアカウントと一緒に消すので、消したあとに、消す前より古い番号の応答が届くと、それを覚える。古い名前が出るのは、プロフィールを開いて読み直すか、ほかの応答で受け取るまで。
/// 起動している間に見た人を上限なく持たないために、この境界を受け入れている。番号だけを残すと、消した人の数だけ番号が溜まり続ける。
public final class ReceivedAccounts: Sendable {
    /// 覚える人数の上限。
    public static let limit = 2_000

    private struct Entry {
        var account: Account
        var order: Int
    }

    private struct State {
        var count = 0
        var entries: CostLimitedCache<String, Entry>
    }

    private let state: Mutex<State>

    /// - Parameter limit: 覚える人数の上限。
    public init(limit: Int = ReceivedAccounts.limit) {
        state = Mutex(State(entries: CostLimitedCache(totalCostLimit: limit)))
    }

    /// 番号をとる。読み込みなら送る前に、書き込みなら応答を受け取ったときに呼ぶ。
    public func nextOrder() -> Int {
        state.withLock { state in
            state.count += 1
            return state.count
        }
    }

    /// 覚えているアカウント。受け取っていなければnil。
    public func account(_ id: String) -> Account? {
        state.withLock { $0.entries.value(forKey: id)?.account }
    }

    /// `order`の番号で受け取った`accounts`を覚える。同じ人をもっとあとの番号で覚えていれば、そちらを残す。
    /// 同じ番号は同じ応答なので、あとに読んだほうで置き換える。
    public func remember(_ accounts: [Account], order: Int) {
        guard !accounts.isEmpty else { return }
        state.withLock { state in
            for account in accounts where state.entries.value(forKey: account.id).map({ $0.order <= order }) ?? true {
                state.entries.setValue(Entry(account: account, order: order), forKey: account.id, cost: 1)
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
