#if DEBUG
import Foundation
import SciaCore

/// デバッグメニューと同じ操作を、`xcrun simctl openurl '<端末>' 'scia-debug://dummy/images'`のようにURLで呼ぶ。
/// agentがメニューを開いてタップせずに、コマンドで確認の準備をするため。
enum DebugURL: Equatable {
    static let scheme = "scia-debug"

    /// `scia-debug://dummy/<DebugDummyPost.rawValue>`
    case dummy(DebugDummyPost)
    /// `scia-debug://unauthorized`。以後のREST APIに401を返させ、トークンが無効になった状態にする。
    case unauthorized
    /// `scia-debug://unreadable`。以後のホームと通知の応答の一部を読めない形に壊し、読み込み直す。
    case unreadable
    /// `scia-debug://status/<ステータスコード>`。以後のREST APIにそのステータスのHTMLのエラーページを返させ、読み込み直す。
    /// `?retry-after=<秒>`を付けると、`Retry-After`ヘッダーも返す。`scia-debug://status/ok`で戻す。
    case status(Int, retryAfter: Int?)
    case statusCleared
    /// `scia-debug://regenerating/on`で、以後のホームの応答を206（サーバーがホームを作り直している最中）にする。`scia-debug://regenerating/off`で戻す。
    case regenerating(Bool)
    /// `scia-debug://unsupported/<OptionalFeature.rawValue>`。以後その機能のAPIに404のHTMLを返させ、このサーバーにはない機能にする。
    case unsupported(OptionalFeature)
    /// `scia-debug://streaming/offline`で今のストリーミングの接続を切り、以後の接続を失敗させる。`scia-debug://streaming/online`で戻す。
    case streaming(isOnline: Bool)
    /// `scia-debug://download/slow`で、以後の共有や保存のためのダウンロードを、進み具合を刻みながら10秒遅らせる。
    /// `?seconds=<秒>`で遅らせる時間を変える。`scia-debug://download/normal`で戻す。
    case slowDownload(seconds: Double?)
    /// `scia-debug://media-limits?image-size=<バイト>&image-matrix=<画素>&video-size=<バイト>&video-matrix=<画素>&video-frame-rate=<fps>`。
    /// 投稿欄が使うサーバーのメディアの上限を、指定した項目だけ差し替える。次に投稿欄で書き始めたときから効く。`scia-debug://media-limits/server`で戻す。
    case mediaLimits(MediaLimits?)
    /// `scia-debug://catalog`で部品のカタログを開く。`scia-debug://catalog/<CatalogComponent.rawValue>`なら、その部品の状態を並べた画面まで開く。
    case catalog(CatalogComponent?)
    /// `scia-debug://dump`。画面にある要素の名前と枠を、アプリのDocuments/AgentDump/screen.txtに書き出す。
    /// agentがスクリーンショットを読まずに、タップする座標や今の画面を文字で知るため。
    case dump
    /// `scia-debug://reset`。重ねた画面をすべて閉じ、どのタブも最初の画面に戻して、ホームのタブを選ぶ。
    case reset
    /// `scia-debug://settings`。設定を開く。
    case settings
    /// `scia-debug://tuning`。チューニングパネルを開く。
    case tuning
    /// `scia-debug://tab/<home|notifications>`。タブを切り替える。
    case tab(Tab)
    /// `scia-debug://viewer?index=<n>`。選んでいるタブの、画面のいちばん上に見えている添付ファイル付きの投稿を、n番目（0から）の添付ファイルでビューアに開く。
    /// サムネイルをタップしたのと同じ経路で開く。
    case viewer(index: Int)
    /// `scia-debug://arrivals/hold`で、以後に届いた新着を一覧に挿入せずに溜める。`scia-debug://arrivals/release`で、溜まった新着をまとめて挿入する。
    /// ストリーミングはつないだままなので、切断の知らせやポーリングで一覧が動かない。
    case holdArrivals(Bool)

    enum Tab: String {
        case home
        case notifications
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host() {
        case "dummy":
            guard let post = DebugDummyPost(rawValue: url.lastPathComponent) else { return nil }
            self = .dummy(post)
        case "unauthorized":
            self = .unauthorized
        case "unreadable":
            self = .unreadable
        case "status":
            if url.lastPathComponent == "ok" {
                self = .statusCleared
                return
            }
            guard let statusCode = Int(url.lastPathComponent), (100..<600).contains(statusCode) else { return nil }
            let retryAfter = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "retry-after" }?.value
            self = .status(statusCode, retryAfter: retryAfter.flatMap { Int($0) })
        case "regenerating":
            switch url.lastPathComponent {
            case "on": self = .regenerating(true)
            case "off": self = .regenerating(false)
            default: return nil
            }
        case "unsupported":
            guard let feature = OptionalFeature(rawValue: url.lastPathComponent) else { return nil }
            self = .unsupported(feature)
        case "streaming":
            switch url.lastPathComponent {
            case "offline": self = .streaming(isOnline: false)
            case "online": self = .streaming(isOnline: true)
            default: return nil
            }
        case "download":
            switch url.lastPathComponent {
            case "slow":
                let seconds = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "seconds" }?.value
                self = .slowDownload(seconds: seconds.flatMap { Double($0) } ?? 10)
            case "normal": self = .slowDownload(seconds: nil)
            default: return nil
            }
        case "media-limits":
            if url.lastPathComponent == "server" {
                self = .mediaLimits(nil)
                return
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> Int? { items.first { $0.name == name }?.value.flatMap { Int($0) } }
            self = .mediaLimits(MediaLimits(
                imageSizeLimit: value("image-size"),
                imageMatrixLimit: value("image-matrix"),
                videoSizeLimit: value("video-size"),
                videoMatrixLimit: value("video-matrix"),
                videoFrameRateLimit: value("video-frame-rate")
            ))
        case "catalog":
            let path = url.path(percentEncoded: false)
            if path.isEmpty || path == "/" {
                self = .catalog(nil)
                return
            }
            guard let component = CatalogComponent(rawValue: url.lastPathComponent) else { return nil }
            self = .catalog(component)
        case "dump":
            self = .dump
        case "reset":
            self = .reset
        case "settings":
            self = .settings
        case "tuning":
            self = .tuning
        case "tab":
            guard let tab = Tab(rawValue: url.lastPathComponent) else { return nil }
            self = .tab(tab)
        case "arrivals":
            switch url.lastPathComponent {
            case "hold": self = .holdArrivals(true)
            case "release": self = .holdArrivals(false)
            default: return nil
            }
        case "viewer":
            let index = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "index" }?.value
            guard let index = Int(index ?? "0"), index >= 0 else { return nil }
            self = .viewer(index: index)
        default:
            return nil
        }
    }
}
#endif
