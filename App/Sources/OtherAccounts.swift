import Foundation
import SciaCore

/// 投稿のメニューの「別のアカウントで」に並べる、ログインしているほかのアカウントを、ウィンドウの画面一式から読むもの。決まりはdocs/other-accounts.mdにある。
/// アカウントごとのクライアントと、そのアカウントで見つけた投稿は、ウィンドウをまたいで共有する`SignedInAccounts`から取る。
/// ここには、ウィンドウごとに要るもの（絵文字のパレットのメニュー、リアクションの絵文字ピッカー、ハッシュタグの操作の通知先）だけを持つ。
/// 401を受けたら、そのアカウントはログアウトされたとする。今のアカウントのログインし直しの段にはつなげず、操作の失敗の理由として知らせる。
@MainActor
final class OtherAccounts {
    private let current: Credential
    private let tasks: TaskScope
    private let shared: SignedInAccounts
    private let registry: @MainActor () -> AccountRegistry?
    /// ウィンドウに開いたアカウントの設定。ほかのアカウントで出す部品も、ウィンドウの見た目で描く。
    private let settings: AppSettings
    /// 絵文字のパレットのカスタム絵文字のメニューが使う、セッションの部品。
    var paletteMenu = EmojiPaletteMenuContext()
    /// ハッシュタグの変更が済んだことを、どのアカウントで行ったかを添えて知らせる。
    var onHashtagDone: (OtherAccount, String) -> Void = { _, _ in }
    /// ハッシュタグの変更の失敗を、どのアカウントで行ったかを添えて知らせる。
    var onHashtagFailure: (OtherAccount, String, any Error) -> Void = { _, _, _ in }

    /// - Parameters:
    ///   - current: このセッションのアカウント。並べない。
    ///   - tasks: 探し直す処理を始めるセッションの持ち主。
    ///   - shared: ウィンドウをまたいで共有する、アカウントごとの部品。
    ///   - registry: ログインしているアカウント。
    init(current: Credential, tasks: TaskScope, settings: AppSettings, shared: SignedInAccounts = AppDependencies.signedInAccounts, registry: @escaping @MainActor () -> AccountRegistry? = { try? AppDependencies.accounts.get() }) {
        self.settings = settings
        self.registry = registry
        self.current = current
        self.tasks = tasks
        self.shared = shared
    }

    private func signedIn(_ account: OtherAccount) -> SignedInAccount {
        shared.account(account.credential)
    }

    func displaySettings(for account: OtherAccount) -> AppSettings {
        signedIn(account).displaySettings
    }

    /// 今ログインしているほかのアカウント。アカウントの切り替えのメニューと同じ順。開くたびに読み、追加やログアウトに追いつく。
    /// - Parameter loadsProfiles: 読めていないアイコンと、サーバーの対応を再読み込みするか。メニューを開くときだけ読む。メニューを開かずに組むとき（アクションバーのボタンを有効にするかを決めるとき）は読まず、スクロールで投稿を組むたびにほかのサーバーへ通信しないようにする。
    func list(loadsProfiles: Bool = true) -> [OtherAccount] {
        guard let registry = registry() else { return [] }
        let listed = registry.accounts.filter { $0.id != current.id }.map { shared.account($0).account }
        guard loadsProfiles else { return listed }
        // 読めていないアイコンは、次に開いたときに出せるよう再読み込みする。
        for account in listed {
            account.loadProfile()
            // 「リアクション」を出すかを、そのアカウントのサーバーで決める（docs/emoji-reaction.md）。
            account.loadCapabilities()
        }
        return listed
    }

    /// 前に見つけた`status`と、それに出る人の関係を、見つけたアカウントで再読み込みする。「別のアカウントで」を組んだメニューを出すときに呼び、次に開いたときから使う。
    /// - Parameters:
    ///   - people: 投稿のほかにメニューに出る人。組んだメニューの`otherAccountPeople`を渡す。
    ///   - relationIDs: 見つかった投稿で、関係の項目を出す人のID。組んだメニューの`otherAccountRelationIDs`を渡す。
    func refresh(_ status: Status, people: [Account], relationIDs: @escaping @MainActor (Status, OtherAccount) -> [String]) {
        for account in list(loadsProfiles: false) where account.known(status) != nil {
            tasks.run(.action) { await account.refresh(status, people: people, relationIDs: relationIDs) }
        }
    }

    /// 「アカウントを管理」の画面で、そのアカウントのトークンでそのアカウント自身を読むもの。
    func ownAccount(of credential: Credential) -> @Sendable () async throws -> Account {
        shared.ownAccount(of: credential)
    }

    /// ほかのアカウントでログインしているか。プロフィールの読み込みを起こさないので、投稿欄のボタンを並べ直すたびに読んでよい。
    var hasOthers: Bool {
        guard let registry = registry() else { return false }
        return registry.accounts.contains { $0.id != current.id }
    }

    /// ログインしているほかのアカウントのうち、`Credential.id`が`id`のもの。ログアウトしていればnil。
    func account(id: String) -> OtherAccount? {
        guard id != current.id, let credential = registry()?.accounts.first(where: { $0.id == id }) else { return nil }
        return shared.account(credential).account
    }

    /// `account`で書くときの、サーバーの上限とアカウントの設定を読むもの。今のアカウントと同じく、一度読めたら使い回す。
    func composeDefaults(of account: OtherAccount) -> @MainActor () async -> (configuration: InstanceConfiguration?, preferences: ServerPreferences?) {
        let signedIn = signedIn(account)
        return { await signedIn.composeDefaults() }
    }

    /// `account`としてAPIを呼ぶクライアントを、呼ぶたびにそのアカウントの今の認証情報で作るもの。
    /// 投稿欄のように長く持つ送り先に渡す。持っている間にログインし直しても、新しいトークンで送るため。
    /// ログアウトしていれば、送らずに失敗するクライアントを作る。ログアウトはサーバーのトークンを取り消さないので、渡したときの認証情報で送ると通ってしまうため。
    func latestClient(for account: OtherAccount) -> @MainActor @Sendable () -> MastodonClient {
        let given = account.credential
        return { [registry, shared] in
            guard let credential = registry()?.accounts.first(where: { $0.id == given.id }) else {
                return MastodonClient(credential: given, transport: RemovedAccountTransport(handle: given.handle), isOtherAccount: true)
            }
            return shared.account(credential).client
        }
    }

    /// `account`として、ハッシュタグのフォロー、ミュート、プロフィールでの紹介を読んで変えるもの。済んだことと失敗は、このウィンドウに知らせる。
    func hashtagActions(for account: OtherAccount) -> HashtagMenuActions {
        signedIn(account).hashtags.actions(report: .init(
            done: { [weak self, weak account] title in
                guard let account else { return }
                self?.onHashtagDone(account, title)
            },
            failure: { [weak self, weak account] title, error in
                guard let account else { return }
                self?.onHashtagFailure(account, title, error)
            }
        ))
    }

    /// アカウントごとの、リアクションする絵文字ピッカー。そのアカウントのサーバーのカスタム絵文字と、そのサーバーで最近使った絵文字を出す。ログインし直したら作り直す。
    private var emojiReactionPickers: [Credential.ID: (credential: Credential, picker: EmojiReactionPicker)] = [:]

    /// `account`としてリアクションする絵文字ピッカー。
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
        signedIn(account).client
    }

    /// ほかのアカウントのプロフィールを読み、「別のアカウントで」の行にアイコンを出せるようにする。読めなかったアカウントは、次にメニューを組むときに再読み込みする。
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
