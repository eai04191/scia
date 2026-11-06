public import Foundation
import os

/// ログインしているアカウント1つ分の部品を組み立て、閉じるまで持つ。
///
/// 部品どうしの次の決まりを、ここでまとめて守る。アプリは、通信の実体（`HTTPTransport`、`WebSocketConnector`）と、
/// OSから来るもの（電波が戻った回数）と、画面だけを渡す。
/// - RESTとストリーミングで、429や503で自動の通信を止める門（`RateLimitGate`）を共有する。別々だと、ストリーミングが断られてもRESTの自動の通信が止まらない
/// - 一覧とストリーミングが受けた401を`AuthorizationCheck`へ流し、トークンが無効と決まったら、ストリーミングと一覧の自動の通信を止める
/// - レート制限が明けたときと、電波が戻ったときに、ストリーミングと一覧の失敗したままの読み込みをすぐやり直させる
/// - 閉じたら、申し込みが残っていてもストリーミングを切り、セッションで始めた処理を止める
///
/// 一覧のモデルは、`init(…session:…)`で作ると、ここに登録され、やり直しと止めるのをまとめて受け取る。
@MainActor
public final class AccountSession {
    public let credential: Credential
    public let client: MastodonClient
    /// 各一覧で共有する、ストリーミングの接続。
    public let streamingHub: StreamingHub
    /// 429や503で止められたときに、自動の通信を控える。RESTとストリーミングで共有する。
    public let rateLimit: RateLimitGate
    /// 使えないと分かった機能を、このセッションの間だけ止める。次の起動では作り直し、もう一度試す。
    public let features: FeatureAvailability
    public let requestLog: RequestLog
    /// APIが401を返したときに、トークンが本当に無効かを確かめる。
    public let authorization: AuthorizationCheck
    /// セッションの持ち主。一覧、開いた画面、投稿欄の処理は、この子で始める。
    public let tasks: TaskScope
    /// トークンが無効と確かめられ、ストリーミングと登録した一覧を止めたあとに呼ぶ。ログインし直しを促す表示はアプリが出す。
    public var onCredentialsInvalid: () -> Void = {}
    /// アカウントの設定を初めて読めたときに呼ぶ。
    public var onPreferencesLoad: (ServerPreferences) -> Void = { _ in }
    /// 読めたアカウントの設定。まだ読めていなければnil。
    public private(set) var preferences: ServerPreferences?
    private var instanceConfiguration: InstanceConfiguration?
    /// サーバーの、Mastodonにない機能の有無。読めていないうちと、読めなかったときはMastodonと同じ。
    public private(set) var capabilities = ServerCapabilities.mastodon
    /// サーバーが投稿への絵文字のリアクションに対応しているか（docs/emoji-reaction.md）。
    public var supportsEmojiReactions: Bool { capabilities.supportsEmojiReactions }
    /// サーバーの機能の有無を読めたときに呼ぶ。
    public var onCapabilitiesLoad: (ServerCapabilities) -> Void = { _ in }
    private var capabilitiesState: CapabilitiesState = .unknown
    private var lists: [WeakList] = []
    private let logger = SciaLog.logger(category: "session")

    /// - Parameters:
    ///   - requestLog: 失敗の記録。デバッグ版では応答の本文も残すものを渡す。
    ///   - tuning: ストリーミングの新着の扱いを、つなぎ始めるたびに読む。
    ///   - clock: ストリーミングのつなぎ直しや、トークンを確かめ直さない間、レート制限が明けるまでを数える。テストでは手で進める時計を渡す。
    ///   - now: 429や503の応答が示した再開の時刻を、待つ長さに直すための今の日付。
    public init(
        credential: Credential,
        transport: any HTTPTransport,
        connector: any WebSocketConnector,
        requestLog: RequestLog = RequestLog(includesBody: false),
        tuning: TuningStore,
        clock: any Clock<Duration> = SystemTime.clock,
        now: @escaping @Sendable () -> Date = SystemTime.now
    ) {
        self.credential = credential
        self.requestLog = requestLog
        let rateLimit = RateLimitGate(now: now, clock: clock)
        self.rateLimit = rateLimit
        let features = FeatureAvailability()
        self.features = features
        let client = MastodonClient(credential: credential, transport: transport, rateLimit: rateLimit, features: features, requestLog: requestLog, clock: clock, now: now)
        self.client = client
        let streaming = StreamingClient(credential: credential, connector: connector, rateLimit: rateLimit, now: now)
        let streamingEndpoint = StreamingEndpoint(client: client)
        let streamingHub = StreamingHub(livePolicy: { TuningCatalog.liveUpdates(in: tuning) }, clock: clock) {
            try await streaming.open(baseURL: try await streamingEndpoint.url())
        }
        self.streamingHub = streamingHub
        authorization = AuthorizationCheck(clock: clock) { try await client.verifyCredentials() }
        let tasks = TaskScope()
        self.tasks = tasks
        // 開いているスレッドなどの購読を、閉じる順に頼らずに止めるため、申し込みが残っていても切る。
        tasks.onClose { [weak streamingHub] in streamingHub?.shutDown() }
        streamingHub.onUnauthorized = { [weak self] in self?.reportUnauthorized() }
        authorization.onChange = { [weak self] state in
            guard state == .invalid else { return }
            self?.credentialsDidBecomeInvalid()
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

    /// 一覧が受けた401を知らせる。トークンが本当に無効かを確かめ、無効なら`onCredentialsInvalid`を呼ぶ。
    public func reportUnauthorized() {
        let authorization = authorization
        tasks.run(.display) { _ = await authorization.reportUnauthorized() }
    }

    /// 一覧を登録し、やり直しと止めるのを受け取らせる。弱く持つので、外す必要はない。
    /// トークンが無効と分かったあとに登録した一覧は、その場で止める。無効になったときに止めた一覧と同じく、ログインし直すまで読まないようにするため。
    public func register(_ list: some SessionList) {
        lists.removeAll { $0.list == nil }
        lists.append(WeakList(list: list))
        if authorization.state == .invalid {
            list.stop()
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

    // MARK: - 投稿欄の既定値

    /// インスタンスの上限。一度読めたら使い回す。読めなければnilを返し、次に呼ばれたときに読み直す。
    public func loadInstanceConfiguration() async -> InstanceConfiguration? {
        if let instanceConfiguration { return instanceConfiguration }
        do {
            instanceConfiguration = try await client.instanceConfiguration()
        } catch {
            // 読めないと添付とペーストが使えないため、違和感レポートで理由を追えるよう残す。
            logger.info("instance configuration unavailable error=\(SciaLog.describe(error), privacy: .public)")
        }
        return instanceConfiguration
    }

    /// サーバーの機能の有無を読む。一度読めたら読み直さない。
    /// 読めなかったら、次にやり直すとき（通信が戻ったときなど）にまた読む。起動のときの一時的な失敗で、ずっとMastodonと同じ扱いのままにしないため。
    public func loadCapabilities() {
        guard capabilitiesState == .unknown else { return }
        capabilitiesState = .loading
        let client = client
        tasks.run(.display) { [weak self] in
            do {
                let loaded = try await client.serverCapabilities()
                guard let self else { return }
                capabilitiesState = .loaded
                capabilities = loaded
                logger.info("server capabilities loaded emojiReaction=\(loaded.supportsEmojiReactions, privacy: .public) localTimeline=\(loaded.hasLocalTimeline, privacy: .public)")
                onCapabilitiesLoad(loaded)
            } catch {
                guard let self else { return }
                capabilitiesState = .unknown
                logger.info("server capabilities unavailable error=\(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    private enum CapabilitiesState {
        case unknown, loading, loaded
    }

    /// アカウントの設定。一度読めたら使い回す。読めなければnilを返し、次に呼ばれたときに読み直す。
    @discardableResult
    public func loadPreferences() async -> ServerPreferences? {
        if let preferences { return preferences }
        do {
            let loaded = try await client.preferences()
            preferences = loaded
            onPreferencesLoad(loaded)
            return loaded
        } catch {
            logger.info("preferences unavailable error=\(SciaLog.describe(error), privacy: .public)")
            return nil
        }
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
        model.apply(configuration: loaded, defaultVisibility: loadedPreferences?.defaultVisibility, defaultSensitive: loadedPreferences?.defaultSensitive, defaultLanguage: loadedPreferences.map(\.defaultLanguage))
    }
}

/// `AccountSession`が、レート制限が明けたときや電波が戻ったとき、トークンが無効と分かったときに、まとめて動かす一覧。
@MainActor
public protocol SessionList: AnyObject {
    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。失敗したままの読み込みをすぐやり直す。
    func recover()
    /// トークンが無効と分かったときに呼ぶ。読み込みを打ち切り、以後の結果を捨てる。
    func stop()
}

@MainActor
private struct WeakList {
    weak var list: (any SessionList)?
}
