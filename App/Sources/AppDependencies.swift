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

    static let emojiImages = EmojiImageStore { url in
        try await URLSession.shared.data(from: url).0
    }

    static let avatarImages = AvatarImageStore { url in
        try await URLSession.shared.data(from: url).0
    }

    /// 添付ファイルの元のファイルを置くディスクキャッシュ。ビューアで開いた画像の元のファイルと、共有や保存のために落とした動画などを置く。
    static let mediaFiles = MediaFileCache()

    static let mediaImages = MediaImageStore(files: mediaFiles) { url, range in
        try await MediaImageStore.download(url, range: range)
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

    /// ログインしたアカウントの一覧。シーンをまたいで同じものを使う。Keychainを読めなかったときは、その失敗を持つ。
    static let accounts = Result {
        try AccountRegistry(storage: KeychainCredentialStore(service: "net.mizle.scia.credential"), defaults: .standard)
    }

    static let oauth = OAuthClient(
        configuration: OAuthClient.Configuration(clientName: "Scia", redirectURI: oauthRedirectURI, scopes: "read write"),
        transport: URLSessionTransport()
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
