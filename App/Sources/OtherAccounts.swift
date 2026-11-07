import Foundation
import SciaCore

/// 投稿のメニューの「別のアカウントで」に並べる、ログインしているほかのアカウント。決まりはdocs/menus.mdにある。
/// アカウントごとのクライアントと、そのアカウントで見つけた投稿を、このセッションの間持つ。
/// ほかのアカウントのクライアントは、そのアカウントのセッションとは別に作るため、レート制限の門や使えない機能の記録は共有しない。
/// 401を受けたら、そのアカウントはログアウトされたとする。今のアカウントのログインし直しの段にはつなげず、操作の失敗の理由として知らせる。
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
    /// - Parameter loadsProfiles: 読めていないアイコンと、サーバーの対応を読み直すか。メニューを開くときだけ読む。メニューを開かずに組むとき（アクションバーのボタンを押せるかを決めるとき）は読まず、スクロールで投稿を組むたびにほかのサーバーへ通信しないようにする。
    func list(loadsProfiles: Bool = true) -> [OtherAccount] {
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
        guard loadsProfiles else { return listed }
        // 読めていないアイコンは、次に開いたときに出せるよう読み直す。
        for account in listed {
            account.loadProfile()
            // 「リアクション」を出すかを、そのアカウントのサーバーで決める（docs/emoji-reaction.md）。
            account.loadCapabilities()
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

    /// ほかのアカウントでログインしているか。プロフィールの読み込みを起こさないので、投稿欄のボタンを並べ直すたびに読んでよい。
    var hasOthers: Bool {
        guard let registry = try? AppDependencies.accounts.get() else { return false }
        return registry.accounts.contains { $0.id != current.id }
    }

    /// ログインしているほかのアカウントのうち、`Credential.id`が`id`のもの。ログアウトしていればnil。
    func account(id: String) -> OtherAccount? {
        accounts[id]
    }

    /// アカウントごとの、投稿欄で使うサーバーの上限とアカウントの設定。読めたものを覚え、読めなかったものは次に呼ばれたときに読み直す。
    private var configurations: [Credential.ID: InstanceConfiguration] = [:]
    private var preferences: [Credential.ID: ServerPreferences] = [:]

    /// アカウントごとの、走っている上限と設定の読み込み。書き始めたときと投稿するアカウントを替えたときに重ねて呼ばれても、送り直さずに待つ。
    private var composeDefaultsLoads: [Credential.ID: Task<Void, Never>] = [:]

    /// `account`で書くときの、サーバーの上限とアカウントの設定を読むもの。今のアカウントと同じく、一度読めたら使い回す。
    func composeDefaults(of account: OtherAccount) -> @MainActor () async -> (configuration: InstanceConfiguration?, preferences: ServerPreferences?) {
        let id = account.credential.id
        let client = client(for: account)
        return { [weak self] in
            guard let self else { return (nil, nil) }
            if configurations[id] == nil || preferences[id] == nil {
                let load = composeDefaultsLoads[id] ?? startLoadingComposeDefaults(id: id, client: client)
                await load?.value
            }
            return (configurations[id], preferences[id])
        }
    }

    private func startLoadingComposeDefaults(id: Credential.ID, client: MastodonClient) -> Task<Void, Never>? {
        let needsConfiguration = configurations[id] == nil
        let needsPreferences = preferences[id] == nil
        // 始めた読み込みは、このあとの代入を終えてから走るので、走り終えたときに自分で除ける。
        let load = tasks.run(.action) { [weak self] in
            async let fetchedConfiguration = needsConfiguration ? try? client.instanceConfiguration() : nil
            async let fetchedPreferences = needsPreferences ? try? client.preferences() : nil
            let (loadedConfiguration, loadedPreferences) = await (fetchedConfiguration, fetchedPreferences)
            guard let self else { return }
            if let loadedConfiguration { configurations[id] = loadedConfiguration }
            if let loadedPreferences { preferences[id] = loadedPreferences }
            composeDefaultsLoads[id] = nil
        }
        composeDefaultsLoads[id] = load
        return load
    }

    /// `account`としてAPIを呼ぶクライアントを、呼ぶたびにそのアカウントの今の認証情報で作るもの。
    /// 投稿欄のように長く持つ送り先に渡す。持っている間にログインし直しても、新しいトークンで送るため。
    /// ログアウトしていれば、渡したときの認証情報で作る。この関数を足す前から、持っている送り先はログアウトしたあとも渡したときのクライアントで送っており、その挙動は変えない。
    func latestClient(for account: OtherAccount) -> @MainActor @Sendable () -> MastodonClient {
        let given = account.credential
        let makeClient = makeClient
        return {
            let credential = (try? AppDependencies.accounts.get())?.accounts.first { $0.id == given.id } ?? given
            return makeClient(credential)
        }
    }

    /// アカウントごとの、リアクションする絵文字を選ぶシート。そのアカウントのサーバーのカスタム絵文字と、そのサーバーで最近使った絵文字を出す。ログインし直したら作り直す。
    private var emojiReactionPickers: [Credential.ID: (credential: Credential, picker: EmojiReactionPicker)] = [:]

    /// `account`としてリアクションする絵文字を選ぶシート。
    func emojiReactionPicker(for account: OtherAccount) -> EmojiReactionPicker {
        let credential = account.credential
        if let known = emojiReactionPickers[credential.id], known.credential == credential {
            return known.picker
        }
        let picker = EmojiReactionPicker(completion: TextInputCompletion(
            completion: ComposeCompletion(sources: ComposeCompletion.Sources(client: client(for: account)), settings: TuningCatalog.completionSettings(in: AppDependencies.tuning)),
            recentEmojis: RecentEmojis(defaults: .standard, instance: credential.instance)
        ))
        emojiReactionPickers[credential.id] = (credential, picker)
        return picker
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
