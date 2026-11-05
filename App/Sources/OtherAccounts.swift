import SciaCore

/// 投稿のメニューの「別のアカウントで」に並べる、ログインしているほかのアカウント。決まりはdocs/menus.mdにある。
/// アカウントごとのクライアントと、そのアカウントで見つけた投稿を、このセッションの間持つ。
/// ほかのアカウントのクライアントは、そのアカウントのセッションとは別に作るため、レート制限の門や使えない機能の記録は共有しない。
/// 401を受けても、そのアカウントのログアウトやログインし直しの表示にはつなげず、操作の失敗として知らせる。
@MainActor
final class OtherAccounts {
    private let current: Credential
    private let tasks: TaskScope
    private let makeClient: (Credential) -> MastodonClient
    private var accounts: [Credential.ID: OtherAccountStatuses] = [:]

    /// - Parameters:
    ///   - current: このセッションのアカウント。並べない。
    ///   - tasks: 探し直す処理を始めるセッションの持ち主。
    ///   - makeClient: ほかのアカウントのクライアントを作る。このセッションと同じ通信の実体を使う。
    init(current: Credential, tasks: TaskScope, makeClient: @escaping (Credential) -> MastodonClient) {
        self.current = current
        self.tasks = tasks
        self.makeClient = makeClient
    }

    /// 今ログインしているほかのアカウント。アカウントの切り替えのメニューと同じ順。開くたびに読み、追加やログアウトに追いつく。
    func list() -> [OtherAccountStatuses] {
        guard let registry = try? AppDependencies.accounts.get() else { return [] }
        let credentials = registry.accounts.filter { $0.id != current.id }
        var kept: [Credential.ID: OtherAccountStatuses] = [:]
        let listed = credentials.map { credential in
            // ログインし直してトークンが変わったアカウントは作り直す。
            let account = accounts[credential.id].flatMap { $0.credential == credential ? $0 : nil }
                ?? OtherAccountStatuses(credential: credential, operations: .init(client: makeClient(credential)), tasks: tasks)
            kept[credential.id] = account
            return account
        }
        accounts = kept
        return listed
    }

    /// 前に見つけた`status`を、見つけたアカウントで探し直す。「別のアカウントで」を組んだメニューを出すときに呼び、次に開いたときから使う。
    func refresh(_ status: Status) {
        for account in accounts.values where account.known(status) != nil {
            tasks.run(.action) { _ = await account.lookup(status) }
        }
    }
}
