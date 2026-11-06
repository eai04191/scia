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
    /// アカウントごとの、ハッシュタグの状態を読んで変えるもの。アカウントと一緒に作り直す。
    private var hashtags: [Credential.ID: OtherAccountHashtags] = [:]
    /// ハッシュタグの変更が済んだことを、どのアカウントで行ったかを添えて知らせる。
    var onHashtagDone: (OtherAccount, String) -> Void = { _, _ in }
    /// ハッシュタグの変更の失敗を、どのアカウントで行ったかを添えて知らせる。
    var onHashtagFailure: (OtherAccount, String, any Error) -> Void = { _, _, _ in }

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
        var keptHashtags: [Credential.ID: OtherAccountHashtags] = [:]
        let listed = credentials.map { credential in
            // ログインし直してトークンが変わったアカウントは作り直す。
            if let account = accounts[credential.id], account.credential == credential, let hashtags = hashtags[credential.id] {
                kept[credential.id] = account
                keptHashtags[credential.id] = hashtags
                return account
            }
            let client = makeClient(credential)
            let account = OtherAccount(credential: credential, operations: .init(client: client), tasks: tasks)
            // 同じタグへの操作を重ねて送らない仕組みが、ほかのアカウントの操作まで止めないよう、アカウントごとの子で始める。
            let hashtags = OtherAccountHashtags(client: client, tasks: tasks.child())
            hashtags.onDone = { [weak self, weak account] title in
                guard let account else { return }
                self?.onHashtagDone(account, title)
            }
            hashtags.onFailure = { [weak self, weak account] title, error in
                guard let account else { return }
                self?.onHashtagFailure(account, title, error)
            }
            account.hashtagActions = hashtags.actions
            kept[credential.id] = account
            keptHashtags[credential.id] = hashtags
            return account
        }
        accounts = kept
        hashtags = keptHashtags
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

    /// `account`としてAPIを呼ぶクライアント。そのアカウントのシートに渡す。
    func client(for account: OtherAccount) -> MastodonClient {
        makeClient(account.credential)
    }

    /// ほかのアカウントのプロフィールを読み、「別のアカウントで」の行にアイコンを出せるようにする。読めなかったアカウントは、次にメニューを組むときに読み直す。
    func loadProfiles() {
        _ = list()
    }
}
