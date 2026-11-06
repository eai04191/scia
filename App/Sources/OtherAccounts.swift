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
    private var accounts: [Credential.ID: OtherAccount] = [:]

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
    func list() -> [OtherAccount] {
        guard let registry = try? AppDependencies.accounts.get() else { return [] }
        let credentials = registry.accounts.filter { $0.id != current.id }
        var kept: [Credential.ID: OtherAccount] = [:]
        let listed = credentials.map { credential in
            // ログインし直してトークンが変わったアカウントは作り直す。
            let account = accounts[credential.id].flatMap { $0.credential == credential ? $0 : nil }
                ?? OtherAccount(credential: credential, operations: .init(client: makeClient(credential)), tasks: tasks)
            kept[credential.id] = account
            return account
        }
        accounts = kept
        // 読めていないアイコンは、次に開いたときに出せるよう読み直す。
        for account in listed {
            account.loadProfile()
        }
        return listed
    }

    /// 前に見つけた`status`と、それに出る人の関係を、見つけたアカウントで読み直す。「別のアカウントで」を組んだメニューを出すときに呼び、次に開いたときから使う。
    /// - Parameters:
    ///   - people: 投稿のほかにメニューに出る人。組んだメニューの`otherAccountPeople`を渡す。
    ///   - relationIDs: 見つかった投稿で、関係の項目を出す人のID。組んだメニューの`otherAccountRelationIDs`を渡す。
    func refresh(_ status: Status, people: [Account], relationIDs: @escaping @MainActor (Status, OtherAccount) -> [String]) {
        for account in accounts.values where account.known(status) != nil {
            tasks.run(.action) { await account.refresh(status, people: people, relationIDs: relationIDs) }
        }
    }

    /// ほかのアカウントのプロフィールを読み、「別のアカウントで」の行にアイコンを出せるようにする。読めなかったアカウントは、次にメニューを組むときに読み直す。
    func loadProfiles() {
        _ = list()
    }
}
