import Foundation
import SciaCore

/// ログインしているアカウントごとの、ウィンドウをまたいで共有する部品。アプリに1つ置き、使われたアカウントの分だけ作る。決まりはdocs/other-accounts.mdにある。
/// ログアウトしたアカウントと、ログインし直してトークンが変わったアカウントの部品は、ログインしているアカウントの変化を購読して閉じる。
/// ここで作るクライアントは、そのアカウントのウィンドウのセッションとは別に作るため、レート制限の門や使えない機能の記録は共有しない。
@MainActor
final class SignedInAccounts {
    private let settings: AppSettings
    private let registry: @MainActor () -> AccountRegistry?
    private let makeClient: (Credential, ReceivedAccounts) -> MastodonClient
    private let tasks = TaskScope()
    private var accounts: [Credential.ID: SignedInAccount] = [:]
    private var observing = false

    /// - Parameters:
    ///   - settings: アプリの設定。アカウントごとの設定はここから作る。
    ///   - registry: ログインしているアカウント。
    ///   - makeClient: アカウントのクライアントを作る。
    init(settings: AppSettings, registry: @escaping @MainActor () -> AccountRegistry?, makeClient: @escaping (Credential, ReceivedAccounts) -> MastodonClient) {
        self.settings = settings
        self.registry = registry
        self.makeClient = makeClient
    }

    /// `credential`の部品。なければ作る。ログインし直してトークンが変わっていれば、前の部品を閉じて作り直す。
    /// ログアウトしたか、ログインし直す前の`credential`（開いたままのメニューが持っていたものなど）には、覚えずに使い捨ての部品を返す。
    /// 覚えると、ログインしているアカウントの部品を古いトークンのもので置き換えてしまうため。
    func account(_ credential: Credential) -> SignedInAccount {
        observeRegistry()
        if let account = accounts[credential.id], account.credential == credential { return account }
        let account = SignedInAccount(credential: credential, settings: settings.forAccount(credential.handle), tasks: tasks.child(), makeClient: makeClient)
        if let registry = registry(), !registry.accounts.contains(credential) { return account }
        accounts[credential.id]?.tasks.close()
        accounts[credential.id] = account
        return account
    }

    /// 作ってある部品のうち、`credentials`にないものと、トークンが変わったものを閉じる。
    private func keep(_ credentials: [Credential]) {
        for (id, account) in accounts where !credentials.contains(account.credential) {
            account.tasks.close()
            accounts[id] = nil
        }
    }

    private func observeRegistry() {
        guard !observing, let registry = registry() else { return }
        observing = true
        tasks.run(.display) { [weak self] in
            for await credentials in Observations({ registry.accounts }) {
                self?.keep(credentials)
            }
        }
    }

    /// 「アカウントを管理」の画面で、そのアカウントのトークンでそのアカウント自身を読むもの。部品を作らずに読む。
    func ownAccount(of credential: Credential) -> @Sendable () async throws -> Account {
        let client = makeClient(credential, ReceivedAccounts())
        return { try await client.ownAccount() }
    }
}

/// ログインしているアカウント1つの、ウィンドウをまたいで共有する部品。ログアウトするか、ログインし直してトークンが変わるまで持つ。
/// 「別のアカウントで」で見つけた投稿や人、ハッシュタグの状態、投稿欄の上限と既定値を、どのウィンドウからも同じものとして読む。
@MainActor
final class SignedInAccount {
    let credential: Credential
    /// このアカウントの部品が始める処理の持ち主。ログアウトで閉じる。
    let tasks: TaskScope
    let client: MastodonClient
    /// このアカウントで読んだ人を描く設定。ユーザーの表示の差し替えは端末に1つなので、どのウィンドウからも同じものを使う。
    let displaySettings: AppSettings
    let account: OtherAccount
    let hashtags: OtherAccountHashtags
    /// このクライアントで読んだ人。表示のつなぎは弱く持つので、ここで持つ。
    private let accounts: AccountCache
    private var configuration: InstanceConfiguration?
    private var preferences: ServerPreferences?
    /// 走っている上限と設定の読み込み。書き始めたときと投稿するアカウントを替えたときに重ねて呼ばれても、送り直さずに待つ。
    private var composeDefaultsLoad: Task<Void, Never>?

    init(credential: Credential, settings: AppSettings, tasks: TaskScope, makeClient: (Credential, ReceivedAccounts) -> MastodonClient) {
        self.credential = credential
        self.tasks = tasks
        displaySettings = settings
        let received = ReceivedAccounts()
        let client = makeClient(credential, received)
        self.client = client
        let accounts = AccountCache(received: received) { ids in try await client.accounts(ids) }
        self.accounts = accounts
        // `ReceivedAccounts`の変化を読むのは1か所だけなので、ここで一度だけつなぐ。
        settings.userDisplays.connect(accounts: accounts, settings: settings, received: received, tasks: tasks)
        account = OtherAccount(credential: credential, operations: .init(client: client), tasks: tasks)
        // 同じタグへの操作を重ねて送らない仕組みが、ほかの処理まで止めないよう、子で始める。
        hashtags = OtherAccountHashtags(client: client, tasks: tasks.child())
    }

    /// 投稿欄で使うサーバーの上限とアカウントの設定。読めたものを覚え、読めなかったものは次に呼ばれたときに読み直す。
    func composeDefaults() async -> (configuration: InstanceConfiguration?, preferences: ServerPreferences?) {
        if configuration == nil || preferences == nil {
            let load = composeDefaultsLoad ?? startLoadingComposeDefaults()
            await load?.value
        }
        return (configuration, preferences)
    }

    private func startLoadingComposeDefaults() -> Task<Void, Never>? {
        let client = client
        let needsConfiguration = configuration == nil
        let needsPreferences = preferences == nil
        // 始めた読み込みは、このあとの代入を終えてから走るので、走り終えたときに自分で除ける。
        let load = tasks.run(.action) { [weak self] in
            async let fetchedConfiguration = needsConfiguration ? try? client.instanceConfiguration() : nil
            async let fetchedPreferences = needsPreferences ? try? client.preferences() : nil
            let (loadedConfiguration, loadedPreferences) = await (fetchedConfiguration, fetchedPreferences)
            guard let self else { return }
            if let loadedConfiguration { configuration = loadedConfiguration }
            if let loadedPreferences { preferences = loadedPreferences }
            composeDefaultsLoad = nil
        }
        composeDefaultsLoad = load
        return load
    }
}
