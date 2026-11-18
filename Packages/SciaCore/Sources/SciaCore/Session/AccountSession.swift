public import Foundation
import os

/// ログインしているアカウント1つ分の部品を組み立て、閉じるまで持つ。
///
/// 部品どうしの次の決まりを、ここでまとめて守る。アプリは、通信の実体（`HTTPTransport`、`WebSocketConnector`）と、
/// OSから来るもの（電波が戻った回数）と、画面だけを渡す。
/// - RESTとストリーミングで、429や503で自動の通信を止める門（`RateLimitGate`）を共有する。別々だと、ストリーミングが断られてもRESTの自動の通信が止まらない
/// - `client`で受けたREST APIの401と、ストリーミングが受けた401を`AuthorizationCheck`へ流し、トークンが無効と決まったら、ストリーミングとタイムラインの自動の通信を止める。
///   `client`の401は、モデルやアプリが拾わなくても流れる。`client`を通さずに受けた401だけを`reportUnauthorized()`で知らせる
/// - レート制限が明けたときと、電波が戻ったときに、ストリーミングとタイムラインの失敗したままの読み込みをすぐやり直させる
/// - 閉じたら、申し込みが残っていてもストリーミングを切り、セッションで始めた処理を止める
/// - アカウントごとに1つ持つ部品（読んだアカウントと関係、接続の状態、Xの投稿、投票、自動翻訳）を作り、設定の変化を流し、閉じたら止める。
///   UIごとに作ると、同じ投稿を画面ごとに読み直したり、設定をオフにしても通信が止まらなかったりする
/// - 使い始めるときの手順（`start(networkRecoveryCount:)`）を1つの入口で行う
///
/// タイムラインのモデルは、`init(…session:…)`で作ると、ここに登録され、やり直しと止めるのをまとめて受け取る。
/// 投稿を並べる一覧は`statuses`にも登録され、自分の操作で変わった投稿（削除、編集、お気に入りなど）を受け取る。
/// iOSのアプリとは別のUIから使うときの入口は、docs/other-ui.mdにある。
@MainActor
public final class AccountSession {
    public let credential: Credential
    public let client: MastodonClient
    /// 各タイムラインで共有する、ストリーミングの接続。
    public let streamingHub: StreamingHub
    /// 429や503で止められたときに、自動の通信を控える。RESTとストリーミングで共有する。
    public let rateLimit: RateLimitGate
    /// 使えないと分かった機能を、このセッションの間だけ止める。次の起動では作り直し、もう一度試す。
    public let features: FeatureAvailability
    public let requestLog: RequestLog
    /// 401を受けたときに、トークンが無効になったかを決める。
    public let authorization: AuthorizationCheck
    /// セッションの持ち主。タイムライン、開いた画面、投稿欄の処理は、この子で始める。
    public let tasks: TaskScope
    /// 投稿を並べる一覧へ、自分の操作で変わった投稿を配る。
    public let statuses: SessionStatuses
    /// `client`とストリーミングが受け取ったアカウントの、IDごとに一番新しいもの。IDからアカウントを引く（メニューや補完に出すアイコン、IDだけを持つ画面の行き先、プロフィールを開くときに最初に出すアカウント）。
    public let accounts: AccountCache
    /// セッションで読んだ相手との関係。プロフィール、メニュー、人のリストで同じものを使い、どこで変えても揃える。
    public let relationships: RelationshipCache
    /// 今の版のサーバーが処理できないと分かった画像の形式。サーバーごとに端末に覚える。
    public let mediaFormats: UnprocessableMediaFormats
    /// 接続の状態。ストリーミングの状態とサーバーの版は、セッションが入れる。
    public let diagnostics: ConnectionDiagnostics
    /// fxtwitterから読んだXの投稿。どの一覧でも同じ投稿を1回だけ読む。設定で展開をオフにしたら、読み込みをやめる（docs/link-card.md）。
    public let xPosts: XPostStore
    /// 投票と、投票の結果の読み直し。結果はどの一覧にも反映する。
    public let polls: PollVoting
    /// 投稿の本文の自動翻訳（docs/auto-translation.md）。訳す部品（`StatusTranslationSetup`）を渡さなければnil。
    public let translations: StatusTranslationStore?
    /// ストリーミングの状態か申し込みが変わったときに呼ぶ。`streamingHub.onChange`はセッションが使うので、UIはここに置く。
    public var onStreamingChange: () -> Void = {}
    /// 自動翻訳の設定（オンオフ、訳す言語、対象外の人、翻訳先、方式）が変わり、`translations`に入れ終えたあとに呼ぶ。出している投稿を描き直す。
    public var onTranslationSettingsChange: () -> Void = {}
    /// トークンが無効になり、ストリーミングと登録したタイムラインを止めたあとに呼ぶ。ログインし直しを促す表示はアプリが出す。
    public var onCredentialsInvalid: () -> Void = {}
    /// アカウントの設定を読めたときと、入れ替えたときに呼ぶ。アニメーションを再生するかは、呼ぶ前にセッションが設定（`AppSettings`）へ覚えさせる。
    public var onPreferencesLoad: (ServerPreferences) -> Void = { _ in }
    /// 読めたアカウントの設定。まだ読めていなければnil。
    public private(set) var preferences: ServerPreferences?
    /// 設定を入れ替えたか、既定を保存した回数。読み始めたあとに増えていたら、その読み込みの応答は古いので使わない。
    /// 起動時の読み込み、画面を開いたときの読み直し、保存のあとの読み直しのどれが遅れて届いても、新しい設定を古い値で上書きしないため。
    @ObservationIgnored private var preferencesVersion = 0
    private var instanceConfiguration: InstanceConfiguration?
    private let configurationLoad = SharedLoad()
    private let preferencesLoad = SharedLoad()
    /// サーバーの、Mastodonにない機能の有無。読めていないうちと、読めなかったときはMastodonと同じ。
    public private(set) var capabilities = ServerCapabilities.mastodon
    /// サーバーが投稿への絵文字のリアクションに対応しているか（docs/emoji-reaction.md）。
    public var supportsEmojiReactions: Bool { capabilities.supportsEmojiReactions }
    /// サーバーの機能の有無を読めたときに呼ぶ。
    public var onCapabilitiesLoad: (ServerCapabilities) -> Void = { _ in }
    private var capabilitiesState: CapabilitiesState = .unknown
    private var capabilitiesLoad: Task<Void, Never>?
    private var lists: [WeakList] = []
    /// このアカウントが使うプリセットの設定。
    public let settings: AppSettings
    private let tuning: TuningStore
    private let translationSetup: StatusTranslationSetup?
    private let logger = SciaLog.logger(category: "session")

    /// - Parameters:
    ///   - http: APIの外の通信の口。アプリで1つ作ったものを渡す。Xの投稿を読むのに使う。
    ///   - settings: アプリの設定。Xの投稿の展開と自動翻訳の設定の変化を追い、サーバーのアニメーションの設定を覚えさせる。
    ///   - defaults: サーバーごとに覚える値（処理できない画像の形式）の置き場所。`AppSettings`に渡したものと同じ。
    ///   - translation: 自動翻訳の、UIが用意する部品。訳せないUIではnil。
    ///   - pollOperations: セッションのクライアントから、投票の通信の口を作る。省略すると、そのクライアントで送る。
    ///   - requestLog: 失敗の記録。デバッグ版では応答の本文も残すものを渡す。
    ///   - tuning: ストリーミングの新着の扱いを、つなぎ始めるたびに読む。
    ///   - clock: ストリーミングのつなぎ直しや、トークンを確かめ直さない間、レート制限が明けるまでを数える。テストでは手で進める時計を渡す。
    ///   - now: 429や503の応答が示した再開の時刻を、待つ長さに直すための今の日付。
    public init(
        credential: Credential,
        transport: any HTTPTransport,
        connector: any WebSocketConnector,
        http: HTTPClient,
        settings: AppSettings,
        defaults: UserDefaults,
        requestLog: RequestLog = RequestLog(includesBody: false),
        tuning: TuningStore,
        translation: StatusTranslationSetup? = nil,
        pollOperations: (MastodonClient) -> PollVoting.Operations = { PollVoting.Operations(client: $0) },
        clock: any Clock<Duration> = SystemTime.clock,
        now: @escaping @Sendable () -> Date = SystemTime.now
    ) {
        self.credential = credential
        self.requestLog = requestLog
        self.settings = settings
        self.tuning = tuning
        translationSetup = translation
        let statuses = SessionStatuses()
        self.statuses = statuses
        let rateLimit = RateLimitGate(now: now, clock: clock)
        self.rateLimit = rateLimit
        let features = FeatureAvailability()
        self.features = features
        // 401を知らせる先のAuthorizationCheckは、確かめるのにこのクライアントを使うので、作ったあとにつなぐ。
        let unauthorized = UnauthorizedRelay()
        let receivedAccounts = ReceivedAccounts()
        let client = MastodonClient(credential: credential, transport: transport, rateLimit: rateLimit, features: features, requestLog: requestLog, clock: clock, now: now, receivedAccounts: receivedAccounts) {
            await unauthorized.report()
        }
        self.client = client
        let accounts = AccountCache(received: receivedAccounts) { ids in try await client.accounts(ids) }
        self.accounts = accounts
        let streaming = StreamingClient(credential: credential, connector: connector, rateLimit: rateLimit, now: now, receivedAccounts: receivedAccounts)
        let streamingEndpoint = StreamingEndpoint(client: client)
        let streamingHub = StreamingHub(livePolicy: { TuningCatalog.liveUpdates(in: tuning) }, clock: clock) {
            try await streaming.open(baseURL: try await streamingEndpoint.url())
        }
        self.streamingHub = streamingHub
        authorization = AuthorizationCheck(clock: clock) { try await client.verifyCredentials() }
        unauthorized.authorization = authorization
        let tasks = TaskScope()
        self.tasks = tasks
        // 閉じたあと（ログアウトやアカウントの切り替えのあと）に届いた401では、ログインし直しを促さない。
        tasks.onClose { unauthorized.authorization = nil }
        // 開いているスレッドなどの購読を、閉じる順に頼らずに止めるため、申し込みが残っていても切る。
        tasks.onClose { [weak streamingHub] in streamingHub?.shutDown() }
        let relationships = RelationshipCache { ids in try await client.relationships(ids) }
        self.relationships = relationships
        // キャッシュが自分で始めた通信も、ログアウトやアカウントの切り替えで止める。
        tasks.onClose { [weak accounts, weak relationships] in
            accounts?.close()
            relationships?.close()
        }
        let mediaFormats = UnprocessableMediaFormats(defaults: defaults, instance: credential.instance)
        self.mediaFormats = mediaFormats
        let diagnostics = ConnectionDiagnostics(rateLimit: rateLimit, features: features, requestLog: requestLog, mediaFormats: mediaFormats)
        self.diagnostics = diagnostics
        xPosts = XPostStore(clock: clock, retryPolicy: { TuningCatalog.imageRetry(in: tuning) }, fetch: { [xPostClient = XPostClient(client: http)] in try await xPostClient.post(id: $0) })
        polls = PollVoting(operations: pollOperations(client)) { id, transform in
            statuses.updateStatus(id, transform)
        }
        translations = translation.map {
            StatusTranslationStore(translator: $0.translator, targetLanguage: $0.targetLanguage(), strategy: $0.strategy(), scope: tasks, clock: clock) {
                .seconds(tuning.value(of: TuningCatalog.translationApplyInterval))
            }
        }
        translations?.setLanguages(settings.effectiveAutoTranslationLanguages)
        translations?.setExcludedAuthors(settings.autoTranslationExcludedHandles, localServer: credential.server)
        // HubはセッションがStrongに持つので、弱く持って循環させない。
        streamingHub.onChange = { [weak self, weak streamingHub] in
            guard let streamingHub else { return }
            diagnostics.setStreaming(streamingHub.state, subscriptions: streamingHub.subscriptions)
            self?.onStreamingChange()
        }
        streamingHub.onUnauthorized = { [weak self] in self?.reportStreamingUnauthorized() }
        authorization.onChange = { [weak self] state in
            guard state == .invalid else { return }
            self?.credentialsDidBecomeInvalid()
        }
        observeXPostSetting()
        observeTranslationSettings()
    }

    /// アカウントを使い始める。画面を出すときに1度呼ぶ。通信はしない。次を行う。
    /// - レート制限が明けたときと、電波が戻ったときのやり直しを始める（`observeRecoveries`）
    /// - サーバーの設定に従う項目を、読み直すまで、前に読めたサーバーの値で描かせる（`AppSettings.followServerPreferences`）
    ///
    /// サーバーから読むものは`loadServerInfo()`で始める。
    /// - Parameter networkRecoveryCount: 電波がつながっていない状態から戻った回数（`NetworkConditionsMonitor.recoveryCount`）。Observationで追える値を返す。
    public func start(networkRecoveryCount: @escaping @MainActor () -> Int) {
        observeRecoveries(networkRecoveryCount: networkRecoveryCount)
        settings.followServerPreferences(of: credential.handle)
    }

    /// 使い始めたアカウントの、サーバーの情報を読む。`start(networkRecoveryCount:)`のあとに1度呼ぶ。次を行う。
    /// 起動してすぐのタイムラインの読み込みと同時に送ると、サーバーで順番待ちになってタイムラインが遅れるため、`start`と分けてある。
    /// - サーバーの版を読み、接続の状態（`diagnostics`）に入れる。読めなくても使うのに困らないので、失敗は記録するだけにする
    /// - 投稿欄が使う上限と既定値、アカウントの設定を先に読む（`preloadComposeDefaults`）。読めたら`onPreferencesLoad`を呼ぶ
    /// - サーバーの機能の有無を読む（`loadCapabilities`）。読めたら`onCapabilitiesLoad`を呼ぶ
    ///
    /// `onPreferencesLoad`、`onCapabilitiesLoad`、`onCredentialsInvalid`は、呼ぶ前に置いておく。
    public func loadServerInfo() {
        loadServerVersion()
        preloadComposeDefaults()
        loadCapabilities()
    }

    /// 原因を絞れるよう、サーバーの版を記録に残す。
    private func loadServerVersion() {
        let client = client
        let instance = credential.instance.host() ?? credential.instance.absoluteString
        tasks.run(.display) { [weak self] in
            do {
                let version = try await client.serverVersion()
                self?.logger.info("server instance=\(instance, privacy: .public) version=\(version, privacy: .public)")
                self?.diagnostics.setServerVersion(version)
            } catch {
                self?.logger.info("server version unavailable instance=\(instance, privacy: .public) error=\(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 設定でXの投稿の展開をオフにしたら、読み込み中のfxtwitterへの通信と読み直しの待ちをやめる。オフのあいだ通信しないため（docs/link-card.md）。
    private func observeXPostSetting() {
        withObservationTracking {
            _ = settings.expandsXPosts
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                guard let self, !self.tasks.isClosed else { return }
                if !self.settings.expandsXPosts {
                    self.xPosts.cancelAll()
                }
                self.observeXPostSetting()
            }
        }
    }

    /// 自動翻訳のオンオフ、訳す言語、対象外の人、翻訳先、翻訳の方式が変わるか、言語モデルが入ったら、ストアに入れ直す。ストアは訳せなかった言語を忘れる。
    private func observeTranslationSettings() {
        guard translations != nil, let translationSetup else { return }
        withObservationTracking {
            _ = settings.effectiveAutoTranslationLanguages
            _ = settings.autoTranslationExcludedHandles
            _ = settings.autoTranslationModelRevision
            // 翻訳先と方式は、UIが設定とOSの状態から決める。決めるのに読んだ値の変化も追う。
            _ = translationSetup.targetLanguage()
            _ = translationSetup.strategy()
        } onChange: { [weak self] in
            Task(.withoutRequests) { @MainActor in
                guard let self, !self.tasks.isClosed, let translations = self.translations, let translationSetup = self.translationSetup else { return }
                translations.setTargetLanguage(translationSetup.targetLanguage())
                translations.setStrategy(translationSetup.strategy())
                translations.setLanguages(self.settings.effectiveAutoTranslationLanguages)
                translations.setExcludedAuthors(self.settings.autoTranslationExcludedHandles, localServer: self.credential.server)
                self.onTranslationSettingsChange()
                self.observeTranslationSettings()
            }
        }
    }

    /// レート制限が明けたときと、電波が戻ったときのやり直しを始める。
    /// - Parameter networkRecoveryCount: 電波がつながっていない状態から戻った回数。Observationで追える値を返す。
    public func observeRecoveries(networkRecoveryCount: @escaping @MainActor () -> Int) {
        let rateLimit = rateLimit
        tasks.run(.display) { [weak self] in
            for await _ in rateLimit.resumptions {
                self?.recover(reason: "rate limit resumed")
            }
        }
        tasks.run(.display) { [weak self] in
            // 最初の値は今の回数なので飛ばす。
            for await _ in Observations({ networkRecoveryCount() }).dropFirst() {
                self?.recover(reason: "network recovered")
            }
        }
    }

    /// REST APIで受けた401を知らせる。確かめずにトークンが無効になったとし、`onCredentialsInvalid`を呼ぶ。理由は`AuthorizationCheck`にある。
    /// `client`で受けた401は`client`が知らせるので、呼ばなくてよい。`client`を通さない通信で受けた401のためにある。
    public func reportUnauthorized() {
        authorization.reportUnauthorized()
    }

    /// ストリーミングで受けた401を知らせる。有効なトークンでも返ることがあるので、確かめて無効なら`onCredentialsInvalid`を呼ぶ。
    public func reportStreamingUnauthorized() {
        let authorization = authorization
        tasks.run(.display) { _ = await authorization.reportStreamingUnauthorized() }
    }

    /// タイムラインを登録し、やり直しと止めるのを受け取らせる。弱く持つので、外す必要はない。
    /// トークンが無効と分かったあとに登録したタイムラインは、その場で止める。無効になったときに止めたタイムラインと同じく、ログインし直すまで読まないようにするため。
    public func register(_ list: some SessionList) {
        lists.removeAll { $0.list == nil }
        lists.append(WeakList(list: list))
        if authorization.state == .invalid {
            list.stop()
        }
    }

    /// 登録したタイムライン（`register(_:)`）の既読位置を待たずに保存し、全部保存し終えるまで待つ。
    /// アプリを終了する前など、保存を待ってから進みたいときに呼ぶ。ストリーミングは切らない。失敗しても投げず、次の機会に保存し直す。
    /// 既読位置は、読み進めてから決まった時間が経ったときと、各タイムラインの`enterBackground()`でも保存するので、ふだんは呼ばなくてよい。
    public func saveReadPositions() async {
        for list in lists.compactMap(\.list) {
            await list.saveReadPosition()
        }
    }

    /// 閉じる。ストリーミングを切り、セッションで始めた処理を全部止める。
    public func close() {
        tasks.close()
    }

    private func recover(reason: String) {
        logger.info("recover reason=\(reason, privacy: .public)")
        loadCapabilities()
        // つながっていなければ、待っている間隔を飛ばしてつなぎ直す。
        streamingHub.recover()
        for list in lists.compactMap(\.list) {
            list.recover()
        }
    }

    /// 自動の通信を止める。資格情報は消さない。消すのは、使う人がログアウトを選んだときだけ。
    private func credentialsDidBecomeInvalid() {
        logger.info("credentials invalid")
        streamingHub.stopUntilLogin()
        for list in lists.compactMap(\.list) {
            list.stop()
        }
        onCredentialsInvalid()
    }

    // MARK: - 投稿欄の口

    /// 投稿欄がメディアのアップロードに使う口。処理できない画像の形式を、このサーバーの版ごとに覚える。
    /// - Parameter makeThumbnail: 添付のサムネイルを、UIの画像の型で作る。
    public func composeMediaService<Thumbnail>(makeThumbnail: @escaping (LocalMediaFile) async -> Thumbnail?) -> ComposeMediaService<Thumbnail> {
        ComposeMediaService(client: { [client] in client }, settings: settings, tuning: tuning, formats: mediaFormats, serverVersion: { [diagnostics] in diagnostics.serverVersion }, makeThumbnail: makeThumbnail)
    }

    /// 投稿欄が「削除して書き直す」に使う口。
    public func composeRedraftService() -> ComposeRedraftService {
        ComposeRedraftService { [client] in client }
    }

    /// ユーザーのメニューの「リストに追加」の通信の口。
    public func listMembershipAPI(accountID: String, acct: String) -> ListMembershipModel.API {
        ListMembershipModel.API(client: { [client] in client }, accountID: accountID, acct: acct)
    }

    // MARK: - 投稿欄の既定値

    /// インスタンスの上限。一度読めたら使い回す。読めなければnilを返し、次に呼ばれたときに読み直す。
    public func loadInstanceConfiguration() async -> InstanceConfiguration? {
        await configurationLoad.run(cached: { instanceConfiguration }) {
            do {
                instanceConfiguration = try await client.instanceConfiguration()
            } catch {
                // 読めないと添付とペーストが使えないため、違和感レポートで理由を追えるよう残す。
                logger.info("instance configuration unavailable error=\(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 投稿欄が使う上限と既定値を、書き始める前に読んでおく。書き始めてから読むと、応答の遅いサーバーでは、届くまで投稿できないため。
    /// 読めなければ、書き始めたときに読み直す。
    public func preloadComposeDefaults() {
        tasks.run(.display) { [weak self] in _ = await self?.loadInstanceConfiguration() }
        tasks.run(.display) { [weak self] in await self?.loadPreferences() }
    }

    /// 走っている上限と既定値の読み込みを待っている呼び出しの数。
    var composeDefaultsWaiterCount: Int { configurationLoad.waiterCount + preferencesLoad.waiterCount }

    /// サーバーの機能の有無を読む。一度読めたら読み直さない。
    /// 読めなかったら、次にやり直すとき（通信が戻ったときなど）にまた読む。起動のときの一時的な失敗で、ずっとMastodonと同じ扱いのままにしないため。
    public func loadCapabilities() {
        guard capabilitiesState == .unknown else { return }
        capabilitiesState = .loading
        let client = client
        capabilitiesLoad = tasks.run(.display) { [weak self] in
            do {
                let loaded = try await client.serverCapabilities()
                self?.didLoad(loaded)
            } catch {
                guard let self, capabilitiesState == .loading else { return }
                capabilitiesState = .unknown
                logger.info("server capabilities unavailable error=\(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 読めたサーバーの機能の有無。読めていればそれを返し、読んでいる途中なら終わるのを待つ。それでも読めていなければ読み、読めなければ投げる。
    /// Mastodonと同じとみなして進むと取り違えるところ（引用を送るパラメーターの名前）で使う。
    public func loadedCapabilities() async throws -> ServerCapabilities {
        loadCapabilities()
        await capabilitiesLoad?.value
        if capabilitiesState == .loaded { return capabilities }
        let loaded = try await client.serverCapabilities()
        didLoad(loaded)
        return capabilities
    }

    private func didLoad(_ loaded: ServerCapabilities) {
        guard capabilitiesState != .loaded else { return }
        capabilitiesState = .loaded
        capabilities = loaded
        logger.info("server capabilities loaded emojiReaction=\(loaded.supportsEmojiReactions, privacy: .public) localTimeline=\(loaded.hasLocalTimeline, privacy: .public) quotes=\(String(describing: loaded.quotes), privacy: .public)")
        onCapabilitiesLoad(loaded)
    }

    /// 下書きをこのアカウントのサーバーへ送る。`ComposeModel`の`submit`に渡す。
    /// 引用のある下書きは、読めたサーバーの引用の決まりで送り、決まりを読めなければ送らない。
    public func submit(_ draft: StatusDraft) async throws -> SubmittedDraft {
        try await client.submit(draft) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await loadedCapabilities().quotes
        }
    }

    private enum CapabilitiesState {
        case unknown, loading, loaded
    }

    /// アカウントの設定。一度読めたら使い回す。読めなければnilを返し、次に呼ばれたときに読み直す。
    @discardableResult
    public func loadPreferences() async -> ServerPreferences? {
        await preferencesLoad.run(cached: { preferences }) {
            do {
                let version = preferencesVersion
                adoptPreferences(try await client.preferences(), readAt: version)
            } catch {
                logger.info("preferences unavailable error=\(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// アカウントの設定を読み直す。ほかのクライアントで変えた値を拾うために、設定を見せる画面を開くときに呼ぶ。読めなければ投げ、手元の設定は変えない。
    @discardableResult
    public func reloadPreferences() async throws -> ServerPreferences {
        let version = preferencesVersion
        return adoptPreferences(try await client.preferences(), readAt: version)
    }

    /// 読んだ設定を入れ、配る。読み始めたあとに、ほかの読み込みや保存が設定を入れ替えていたら、読んだのはその前の値なので使わず、今の設定を返す。
    @discardableResult
    private func adoptPreferences(_ loaded: ServerPreferences, readAt version: Int) -> ServerPreferences {
        if preferencesVersion != version, let preferences { return preferences }
        preferencesVersion += 1
        preferences = loaded
        settings.rememberServerAnimations(loaded.autoplaysAnimations, of: credential.handle)
        settings.rememberServerMediaDisplay(loaded.mediaDisplay, of: credential.handle)
        onPreferencesLoad(loaded)
        return loaded
    }

    /// 新しく投稿するときの既定を1つ変え、変えたあとのアカウントの設定を返す。決まりはdocs/account-screen.mdの「投稿のデフォルト」にある。
    /// 保存できたら設定を読み直す。読み直せなければ、送った変更を手元の設定に当てる。保存できなければ投げ、手元の設定は変えない。
    @discardableResult
    public func updatePostingDefault(_ change: PostingDefaultChange) async throws -> ServerPreferences? {
        try await client.updatePostingDefault(change)
        // 保存の前に読み始めた応答を、ここから先は使わせない。
        preferencesVersion += 1
        let version = preferencesVersion
        guard let updated = (try? await client.preferences()) ?? preferences.map(change.applied(to:)) else { return nil }
        return adoptPreferences(updated, readAt: version)
    }

    /// インスタンスの上限と、アカウントの既定の公開範囲、閲覧注意、言語を読み、投稿欄に反映する。
    /// `ComposeModel`は反映するまで投稿させないので、書き始めるときに呼ぶ。読めなかった値は既定のまま使えるようにし、次に呼ばれたときに読み直す。
    /// - Parameter adjustingConfiguration: 反映する前に上限を差し替える。デバッグ版で、送る前に縮める流れを確かめるのに使う。
    public func applyComposeDefaults<Thumbnail>(
        to model: ComposeModel<Thumbnail>,
        adjustingConfiguration: (InstanceConfiguration?) -> InstanceConfiguration? = { $0 }
    ) async {
        async let configuration = loadInstanceConfiguration()
        async let preferences = loadPreferences()
        let loaded = adjustingConfiguration(await configuration)
        let loadedPreferences = await preferences
        model.apply(configuration: loaded, defaultVisibility: loadedPreferences?.defaultVisibility, defaultSensitive: loadedPreferences?.defaultSensitive, defaultLanguage: loadedPreferences.map(\.defaultLanguage), defaultQuotePolicy: loadedPreferences.map(\.defaultQuotePolicy))
    }
}

/// `AccountSession`が、レート制限が明けたときや電波が戻ったとき、トークンが無効と分かったときに、まとめて動かすタイムライン。
@MainActor
public protocol SessionList: AnyObject {
    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。失敗したままの読み込みをすぐやり直す。
    func recover()
    /// トークンが無効と分かったときに呼ぶ。読み込みを打ち切り、以後の結果を捨てる。
    func stop()
    /// `AccountSession.saveReadPositions()`で呼ぶ。既読位置があれば待たずに保存し、保存し終えるまで待つ。既読位置のない一覧は何もしない。
    func saveReadPosition() async
}

extension SessionList {
    public func saveReadPosition() async {}
}

/// `MastodonClient`が受けた401を、あとで作る`AuthorizationCheck`へ届ける。
@MainActor
private final class UnauthorizedRelay {
    weak var authorization: AuthorizationCheck?

    func report() {
        authorization?.reportUnauthorized()
    }
}

@MainActor
private struct WeakList {
    weak var list: (any SessionList)?
}

/// 一度読めたら使い回す値の読み込みを、同時に1つだけ走らせる。走っている間に呼ばれたら、送り直さずにそれを待つ。
@MainActor
private final class SharedLoad {
    /// 読み込みが走っている間だけ、待っている呼び出し。
    private var waiters: [CheckedContinuation<Void, Never>]?

    var waiterCount: Int { waiters?.count ?? 0 }

    /// - Parameter cached: 読めていれば、その値。
    /// - Parameter load: 読んで、読めたら`cached`が返す場所に入れる。
    func run<Value>(cached: () -> Value?, load: () async -> Void) async -> Value? {
        // 待っていた読み込みが読めずに終わったら、自分で読み直す。目的が違うと、レート制限で止められている間に送られるかが違うため。
        while waiters != nil {
            await withCheckedContinuation { waiters?.append($0) }
            if let value = cached() { return value }
        }
        if let value = cached() { return value }
        waiters = []
        await load()
        let waiting = waiters ?? []
        waiters = nil
        waiting.forEach { $0.resume() }
        return cached()
    }
}
