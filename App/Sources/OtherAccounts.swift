import Foundation
import SciaCore

/// 投稿のメニューの「別のアカウントで」に並べる、ログインしているほかのアカウント。決まりはdocs/other-accounts.mdにある。
/// アカウントごとのクライアントと、そのアカウントで見つけた投稿を、このセッションの間持つ。
/// ほかのアカウントのクライアントは、そのアカウントのセッションとは別に作るため、レート制限の門や使えない機能の記録は共有しない。
/// 401を受けたら、そのアカウントはログアウトされたとする。今のアカウントのログインし直しの段にはつなげず、操作の失敗の理由として知らせる。
@MainActor
final class OtherAccounts {
    private let current: Credential
    private let tasks: TaskScope
    private let makeClient: (Credential, ReceivedAccounts) -> MastodonClient
    private let registry: @MainActor () -> AccountRegistry?
    /// 窓に開いたアカウントの設定。ほかのアカウントで出す部品も、窓の見た目で描く。
    private let settings: AppSettings
    /// 絵文字のパレットのカスタム絵文字のメニューが使う、セッションの部品。
    var paletteMenu = EmojiPaletteMenuContext()
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
    ///   - registry: ログインしているアカウント。
    ///   - makeClient: ほかのアカウントのクライアントを作る。このセッションと同じ通信の実体を使う。
    init(current: Credential, tasks: TaskScope, settings: AppSettings, registry: @escaping @MainActor () -> AccountRegistry? = { try? AppDependencies.accounts.get() }, makeClient: @escaping (Credential, ReceivedAccounts) -> MastodonClient) {
        self.settings = settings
        self.registry = registry
        self.current = current
        self.tasks = tasks
        self.makeClient = makeClient
    }

    private struct DisplaySource {
        let credential: Credential
        let received: ReceivedAccounts
        let accounts: AccountCache
        let settings: AppSettings
        let tasks: TaskScope
    }
    private var displaySources: [Credential.ID: DisplaySource] = [:]

    private func observedClient(_ credential: Credential) -> MastodonClient {
        if let source = displaySources[credential.id], source.credential == credential {
            return makeClient(credential, source.received)
        }
        displaySources[credential.id]?.tasks.close()
        let received = ReceivedAccounts()
        let client = makeClient(credential, received)
        let accounts = AccountCache(received: received) { ids in try await client.accounts(ids) }
        let context = settings.forAccount(credential.handle)
        let scope = tasks.child()
        context.userDisplays.connect(accounts: accounts, settings: context, received: received, tasks: scope)
        displaySources[credential.id] = DisplaySource(credential: credential, received: received, accounts: accounts, settings: context, tasks: scope)
        return client
    }

    func displaySettings(for account: OtherAccount) -> AppSettings {
        _ = observedClient(account.credential)
        guard let source = displaySources[account.credential.id] else { preconditionFailure("表示の取得元がない") }
        return source.settings
    }

    /// 今ログインしているほかのアカウント。アカウントの切り替えのメニューと同じ順。開くたびに読み、追加やログアウトに追いつく。
    /// - Parameter loadsProfiles: 読めていないアイコンと、サーバーの対応を読み直すか。メニューを開くときだけ読む。メニューを開かずに組むとき（アクションバーのボタンを押せるかを決めるとき）は読まず、スクロールで投稿を組むたびにほかのサーバーへ通信しないようにする。
    func list(loadsProfiles: Bool = true) -> [OtherAccount] {
        guard let registry = registry() else { return [] }
        let credentials = registry.accounts.filter { $0.id != current.id }
        let keptIDs = Set(credentials.map(\.id))
        for (id, source) in displaySources where !keptIDs.contains(id) {
            source.tasks.close()
            displaySources[id] = nil
        }
        var kept: [Credential.ID: OtherAccount] = [:]
        var keptHashtags: [Credential.ID: OtherAccountHashtags] = [:]
        let listed = credentials.map { credential in
            // ログインし直してトークンが変わったアカウントは作り直す。
            if let account = accounts[credential.id], account.credential == credential, let hashtags = hashtags[credential.id] {
                kept[credential.id] = account
                keptHashtags[credential.id] = hashtags
                return account
            }
            let client = observedClient(credential)
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

    /// 「アカウントを管理」の画面で、そのアカウントのトークンでそのアカウント自身を読むもの。
    func ownAccount(of credential: Credential) -> @Sendable () async throws -> Account {
        let client = makeClient(credential, ReceivedAccounts())
        return { try await client.ownAccount() }
    }

    /// ほかのアカウントでログインしているか。プロフィールの読み込みを起こさないので、投稿欄のボタンを並べ直すたびに読んでよい。
    var hasOthers: Bool {
        guard let registry = registry() else { return false }
        return registry.accounts.contains { $0.id != current.id }
    }

    /// ログインしているほかのアカウントのうち、`Credential.id`が`id`のもの。ログアウトしていればnil。
    func account(id: String) -> OtherAccount? {
        // 一覧はメニューを開くときに読み直すので、それまでにほかの窓でログアウトしたアカウントも残っている。
        guard registry()?.accounts.contains(where: { $0.id == id }) == true else { return nil }
        return accounts[id]
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
    /// ログアウトしていれば、送らずに失敗するクライアントを作る。ログアウトはサーバーのトークンを取り消さないので、渡したときの認証情報で送ると通ってしまうため。
    func latestClient(for account: OtherAccount) -> @MainActor @Sendable () -> MastodonClient {
        let given = account.credential
        return { [self] in
            guard let credential = registry()?.accounts.first(where: { $0.id == given.id }) else {
                return MastodonClient(credential: given, transport: RemovedAccountTransport(handle: given.handle), isOtherAccount: true)
            }
            return observedClient(credential)
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
        let client = client(for: account)
        let sources = CompletionModel.Sources(client: client).readingPersonalEmojiSet(with: client) { try await account.loadedCapabilities { try await client.serverCapabilities() } }
        let picker = EmojiReactionPicker(completion: TextInputCompletion(
            completion: CompletionModel(sources: sources, settings: TuningCatalog.completionSettings(in: AppDependencies.tuning)),
            recentEmojis: RecentEmojis(defaults: .standard, instance: credential.instance),
            settings: settings
        ))
        picker.paletteMenu = paletteMenu
        emojiReactionPickers[credential.id] = (credential, picker)
        return picker
    }

    /// `account`としてAPIを呼ぶクライアント。そのアカウントのシートに渡す。
    func client(for account: OtherAccount) -> MastodonClient {
        observedClient(account.credential)
    }

    /// ほかのアカウントのプロフィールを読み、「別のアカウントで」の行にアイコンを出せるようにする。読めなかったアカウントは、次にメニューを組むときに読み直す。
    func loadProfiles() {
        _ = list()
    }
}

/// この端末でログアウトしたアカウントの送り先。送らずに失敗する。
private struct RemovedAccountTransport: HTTPTransport {
    let handle: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw RemovedAccount(handle: handle)
    }
}
