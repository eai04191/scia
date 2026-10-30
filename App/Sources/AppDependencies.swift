import Foundation
import QuartzCore
import SciaCore

/// シーンをまたいで共有する依存。
@MainActor
enum AppDependencies {
    /// Releaseビルドではパネルを出さないため、値を保存せず常に既定値を使う。
    static let tuning: TuningStore = {
        #if DEBUG
        TuningStore(defaults: ScenarioMode.defaults ?? .standard)
        #else
        TuningStore(defaults: nil)
        #endif
    }()

    static let stateDumps = StateDumpRegistry()

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
        if let data = await PreviewImages.data(for: url) {
            return data
        }
        return try await remoteFetch.data(from: url)
    }

    static let emojiImages = EmojiImageStore { url in
        try await imageData(from: url)
    }

    static let avatarImages = AvatarImageStore { url in
        try await imageData(from: url)
    }

    /// 添付ファイルの元のファイルを置くディスクキャッシュ。ビューアで開いた画像の元のファイルと、共有や保存のために落とした動画などを置く。
    static let mediaFiles = MediaFileCache()

    /// ビューアで開く画像を先読みして置く場所。開いていない画像で、ビューアで開いた画像を押し出したり、ストレージの一覧に並べたりしないよう分ける。
    static let mediaPrefetchFiles = MediaFileCache(
        directory: .cachesDirectory.appending(path: "MediaPrefetch"),
        sharingDirectory: .temporaryDirectory.appending(path: "MediaPrefetchSharing"),
        sizeLimit: 100 * 1_024 * 1_024
    )

    static let mediaImages = MediaImageStore(files: mediaFiles, prefetchedFiles: mediaPrefetchFiles) { url, range in
        if range == nil, let data = await PreviewImages.data(for: url) {
            return data
        }
        return try await MediaRangeDownload.data(from: url, range: range, remoteFetch: remoteFetch, http: http)
    }

    static let mediaDownloads = MediaDownloads(files: mediaFiles)

    static let network = NetworkConditionsMonitor()

    static let settings: AppSettings = {
        #if DEBUG
        AppSettings(defaults: ScenarioMode.defaults ?? .standard)
        #else
        AppSettings(defaults: .standard)
        #endif
    }()

    static let appIcon = AppIconSelection()

    /// ファイルアプリと`xcrun simctl get_app_container`から取り出せるよう、Documents配下に置く。
    static let discomfortReports = DiscomfortReportStore(
        directory: URL.documentsDirectory.appending(path: "DiscomfortReports")
    )

    /// ログインしたアカウントの一覧。シーンをまたいで同じものを使う。Keychainを読めなかったときは、その失敗を返し、次に使うときに読み直す。
    static var accounts: Result<AccountRegistry, any Error> { accountsLoad.get() }

    private static let accountsLoad = LoadUntilSucceeded {
        try AccountRegistry(storage: KeychainCredentialStore(service: "net.mizle.scia.credential"), defaults: .standard)
    }

    static let oauth = OAuthClient(
        configuration: OAuthClient.Configuration(clientName: "Scia", redirectURI: oauthRedirectURI, scopes: "read write"),
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
