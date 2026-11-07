import Foundation
import QuartzCore
import SciaCore
import UIKit

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

    /// 画像を読めたら元の大きさを渡し、サーバーが縦横比を返さないカスタム絵文字の縦横比を、リストに残す。
    static let emojiImages: EmojiImageStore<UIImage> = {
        let store = EmojiImageStore { url in
            try await imageData(from: url)
        }
        store.onSourceSize = { url, width, height in customEmojis.learn(url, width: width, height: height) }
        return store
    }()

    /// サーバーごとのカスタム絵文字のリスト。端末に残し、絵文字のパレットを開いたときに読み込み中を挟まずに並べる。
    static let customEmojis = CustomEmojiCaches()

    /// アイコンと添付ファイルの画像のストア。設定の見本の画像は端末で作ったものなので、通信せずに返す。
    static let images = ImageStores(http: http, tuning: tuning, maker: .uiKit, clock: clock) { url in
        await PreviewImages.data(for: url)
    }

    static var avatarImages: AvatarImageStore<UIImage> { images.avatars }

    static var mediaFiles: MediaFileCache { images.mediaFiles }

    static var mediaPrefetchFiles: MediaFileCache { images.mediaPrefetchFiles }

    static var mediaImages: MediaImageStore<UIImage> { images.media }

    static let mediaDownloads = MediaDownloads(files: mediaFiles)

    static let network = NetworkConditionsMonitor()

    /// Macでは、ソフトウェアキーボードがなく、書き始めても投稿欄がその場で広がって押した位置にボタンが来るので、既定で畳まない。
    static let settings: AppSettings = {
        let keepsComposeBarOpen = ProcessInfo.processInfo.isiOSAppOnMac
        #if DEBUG
        return AppSettings(defaults: ScenarioMode.defaults ?? .standard, keepsComposeBarOpenByDefault: keepsComposeBarOpen)
        #else
        return AppSettings(defaults: .standard, keepsComposeBarOpenByDefault: keepsComposeBarOpen)
        #endif
    }()

    static let appIcon = AppIconSelection()

    /// ファイルアプリと`xcrun simctl get_app_container`から取り出せるよう、Documents配下に置く。
    static let discomfortReports = DiscomfortReportStore(
        directory: URL.documentsDirectory.appending(path: "DiscomfortReports")
    )

    /// ログインしたアカウントのリスト。シーンをまたいで同じものを使う。Keychainを読めなかったときは、その失敗を返し、次に使うときに読み直す。
    static var accounts: Result<AccountRegistry, any Error> { accountsLoad.get() }

    private static let accountsLoad = LoadUntilSucceeded {
        try AccountRegistry(storage: KeychainCredentialStore(service: "net.mizle.scia.credential"), defaults: .standard)
    }

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
