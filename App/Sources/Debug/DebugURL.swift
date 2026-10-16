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
    /// `scia-debug://unsupported/<OptionalFeature.rawValue>`。以後その機能のAPIに404のHTMLを返させ、このサーバーにはない機能にする。
    case unsupported(OptionalFeature)
    /// `scia-debug://streaming/offline`で今のストリーミングの接続を切り、以後の接続を失敗させる。`scia-debug://streaming/online`で戻す。
    case streaming(isOnline: Bool)
    /// `scia-debug://download/slow`で、以後の共有や保存のためのダウンロードを、進み具合を刻みながら10秒遅らせる。
    /// `?seconds=<秒>`で遅らせる時間を変える。`scia-debug://download/normal`で戻す。
    case slowDownload(seconds: Double?)
    /// `scia-debug://catalog`で部品のカタログを開く。`scia-debug://catalog/<CatalogComponent.rawValue>`なら、その部品の状態を並べた画面まで開く。
    case catalog(CatalogComponent?)

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
        case "catalog":
            let path = url.path(percentEncoded: false)
            if path.isEmpty || path == "/" {
                self = .catalog(nil)
                return
            }
            guard let component = CatalogComponent(rawValue: url.lastPathComponent) else { return nil }
            self = .catalog(component)
        default:
            return nil
        }
    }
}
#endif
