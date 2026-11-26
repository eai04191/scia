import Foundation
import QuartzCore
import SciaCore
import UIKit

/// シーンをまたいで共有する依存。
@MainActor
enum AppDependencies {
    #if DEBUG
    /// ユニットテストのホストとして起動されたか。XCTestがホストのプロセスに渡す、テストの設定のファイルの場所で見分ける。
    /// UIテストでは、アプリはテストと別のプロセスで起動され、これを受け取らないため、ふだんどおりに始める。
    static let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// ユニットテストのホストの、設定とチューニングの保存先。起動のたびに空にする。
    /// 端末のアプリの保存先を読むと、端末で変えた設定（絵文字をTwemojiにするなど）でテストの結果が変わるため。
    private static let unitTestHostDefaults: UserDefaults? = {
        guard isHostingUnitTests else { return nil }
        let suiteName = "net.mizle.scia.unit-test-host"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("ユニットテストのホストのUserDefaultsを作れない")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }()

    /// 撮影モードとユニットテストのホストでは、端末に残った値を使わない保存先。
    private static var isolatedDefaults: UserDefaults? { ScenarioMode.defaults ?? unitTestHostDefaults }
    #endif

    static let tuning: TuningStore = {
        #if DEBUG
        TuningStore(defaults: isolatedDefaults ?? .standard)
        #else
        TuningStore(defaults: .standard)
        #endif
    }()

    /// デバッグ版では常に出す。撮影モードでは、宣伝の素材に開発用のボタンを映さない。
    static let developerMode: DeveloperMode = {
        #if DEBUG
        DeveloperMode(defaults: ScenarioMode.defaults ?? .standard, isAlwaysEnabled: ScenarioMode.server == nil)
        #else
        DeveloperMode(defaults: .standard, isAlwaysEnabled: false)
        #endif
    }()

    static let stateDumps = StateDumpRegistry()

    /// 投稿の行の処理中のクラッシュを記録し、次の起動から隔離する（docs/crash-quarantine.md）。
    static let postCrashGuard = PostCrashGuard(defaults: .standard, build: BuildInfo.current.build + BuildInfo.current.commit)

    /// 時間をおく処理に渡す、実際の時計。テストでは手で進める時計に差し替える。
    nonisolated static var clock: any Clock<Duration> { SystemTime.clock }

    /// 今の日付。テストでは決まった日付に差し替える。
    nonisolated static func now() -> Date {
        SystemTime.now()
    }

    /// 画面の描き換えと同じ時間（Core Animationの時間）。動きの始まりや経過を、描かれる時刻とそろえて測るのに使う。
    /// 実際の時間に触れてよいのは、こことSciaCoreの`SystemTime`だけにする（`make lint`の`direct_time_access`で止める）。
    nonisolated static func mediaTime() -> CFTimeInterval {
        CACurrentMediaTime()
    }

    /// このプロセスを起動した日時。カーネルが覚えている値を読む。読めなければnil。
    /// 設定のストレージの画面で、これより前に作った一時ファイルを、どこからも使っていない残りとして消すのに使う。
    nonisolated static let processStartDate: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    /// アプリの通信の口。送った数を数え（`RequestBurstLog`）、デバッグでは、障害の差し込みと、ダミー投稿の`data:`のURLを返す口を挟む。
    nonisolated static let transport: any HTTPTransport = {
        #if DEBUG
        BurstMonitoringTransport(base: FaultInjectingTransport(base: URLSessionTransport()), monitor: RequestBurstLog.monitor)
        #else
        BurstMonitoringTransport(base: URLSessionTransport(), monitor: RequestBurstLog.monitor)
        #endif
    }()

    /// APIの外の通信（画像、ファイル、fxtwitter、リンク先のページ）とログインの入口。ホストごとに止める門を、アプリで共有する。
    nonisolated static let http = HTTPClient(transport: transport)

    /// 画像を、APIの外のURLから取得する。2xx以外の応答の本文を、画像として渡さない。
    nonisolated static let remoteFetch = RemoteFetch(client: http)

    /// 画像を、URLから取得する。設定の見本の画像は端末で作ったものなので、通信せずに返す。
    nonisolated static func imageData(from url: URL) async throws -> Data {
        if let data = await localImageData(for: url) {
            return data
        }
        return try await remoteFetch.data(from: url)
    }

    static var emojiImages: EmojiImageStore<UIImage> { images.emojis }

    /// カスタム絵文字の画像を置く場所。端末に残した`api/v1/custom_emojis`の応答に載っているか（A）、いないか（B）で分けて置く。
    static var emojiImageFiles: EmojiImageFiles { images.emojiImageFiles }

    /// 応答が変わったら、端末に置く絵文字の画像を分け直し、自分のサーバーの絵文字の画像をプリフェッチする。
    static let emojiPrefetcher = EmojiPrefetcher()

    /// カスタム絵文字の画像と、それに付く記録を置くフォルダー。設定のストレージの画面は、ここを「カスタム絵文字」に数える。
    static var emojiImageDirectory: URL { images.emojiImageDirectory }

    /// 大きすぎて動かせないと分かった元の画像の記録。
    static var oversizedEmojis: OversizedEmojiRecord { images.oversizedEmojis }

    /// 絵文字のパレットで、静止画が届くまでの間に描くサムネイル。
    static var emojiThumbnails: EmojiThumbnails { images.emojiThumbnails }

    /// サムネイルを、パレットを閉じている間に、端末に置いた画像から作る。
    static let emojiThumbnailBuilder = EmojiThumbnailBuilder()

    static let emojiGlyphImages = EmojiGlyphImageStore()

    /// 絵文字ピッカーのUnicodeの絵文字の画像を、端末に置いて持つ。設定のストレージで「絵文字」に数えるよう、カスタム絵文字の画像と同じフォルダーに置く。
    static let emojiGlyphArchive: EmojiGlyphArchive = {
        let archive = EmojiGlyphArchive(directory: emojiImageDirectory.appending(path: "Glyphs"))
        keepPresetEmojiStyles(in: archive)
        return archive
    }()

    /// どれかのプリセットが使う絵文字の種類を、端末に置いた画像の保存先に渡し続ける。
    private static func keepPresetEmojiStyles(in archive: EmojiGlyphArchive) {
        withObservationTracking {
            archive.keep(styles: settings.store.emojiStylesInPresets)
        } onChange: {
            Task(.withoutRequests) { @MainActor in
                keepPresetEmojiStyles(in: archive)
            }
        }
    }

    static var customEmojis: CustomEmojiCaches { images.customEmojis }

    /// アイコン、添付ファイル、カスタム絵文字の画像のストア。設定の見本の画像は端末で作ったものなので、通信せずに返す。
    static let images = ImageStores(http: http, tuning: tuning, network: network, settings: settings, maker: .uiKit, clock: clock) { url in
        await localImageData(for: url)
    }

    /// 通信せずに返せる画像。部品カタログの見本は`data:`のURLで渡すが、通信の層はhttpとhttps以外を送らない。
    private static func localImageData(for url: URL) -> Data? {
        if url.scheme == "data", developerMode.isEnabled {
            return try? Data(contentsOf: url)
        }
        return PreviewImages.data(for: url)
    }

    static var avatarImages: AvatarImageStore<UIImage> { images.avatars }

    static var mediaFiles: MediaFileCache { images.mediaFiles }

    static var mediaPrefetchFiles: MediaFileCache { images.mediaPrefetchFiles }

    static var mediaImages: MediaImageStore<UIImage> { images.media }

    static let mediaDownloads = MediaDownloads(files: mediaFiles, localImageDirectory: settings.store.userDisplayImageDirectory)

    static let network = NetworkConditionsMonitor()

    /// Macでは、ソフトウェアキーボードがなく、書き始めても投稿欄がその場で広がって選択した位置にボタンが来るので、既定で折りたたまない。
    static let settings: AppSettings = {
        let keepsComposeBarOpen = ProcessInfo.processInfo.isiOSAppOnMac
        #if DEBUG
        return AppSettings(defaults: isolatedDefaults ?? .standard, keepsComposeBarOpenByDefault: keepsComposeBarOpen)
        #else
        return AppSettings(defaults: .standard, keepsComposeBarOpenByDefault: keepsComposeBarOpen)
        #endif
    }()

    static let appIcon = AppIconSelection()

    /// ファイルアプリと`xcrun simctl get_app_container`から取り出せるよう、Documents配下に置く。
    static let discomfortReports = DiscomfortReportStore(
        directory: URL.documentsDirectory.appending(path: "DiscomfortReports")
    )

    /// ログインしたアカウントのリスト。シーンをまたいで同じものを使う。Keychainを読めなかったときは、その失敗を返し、次に使うときに再読み込みする。
    static var accounts: Result<AccountRegistry, any Error> { accountsLoad.get() }

    private static let accountsLoad = LoadUntilSucceeded {
        try AccountRegistry(storage: KeychainCredentialStore(service: "net.mizle.scia.credential"), defaults: .standard)
    }

    /// ログインしているアカウントごとの、ウィンドウをまたいで共有する部品。
    static let signedInAccounts: SignedInAccounts = {
        #if DEBUG
        let transport = BurstMonitoringTransport(base: FaultInjectingTransport(base: ScenarioMode.server?.transport ?? URLSessionTransport()), monitor: RequestBurstLog.monitor)
        #else
        let transport = BurstMonitoringTransport(base: URLSessionTransport(), monitor: RequestBurstLog.monitor)
        #endif
        return SignedInAccounts(settings: settings, registry: { try? accounts.get() }) {
            MastodonClient(credential: $0, transport: transport, isOtherAccount: true, receivedAccounts: $1)
        }
    }()

    static let oauth = OAuthClient(
        configuration: OAuthClient.Configuration(redirectURI: oauthRedirectURI),
        client: http
    )

    /// バンドルIDをスキームにして、他のアプリのURLスキームと衝突しないようにする。
    static let oauthCallbackScheme = "net.mizle.scia"

    private static let oauthRedirectURI: URL = {
        guard let url = URL(string: "\(oauthCallbackScheme)://oauth") else {
            preconditionFailure("OAuthのリダイレクトURIを組み立てられません")
        }
        return url
    }()
}
