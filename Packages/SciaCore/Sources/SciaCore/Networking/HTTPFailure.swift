import Foundation

/// 失敗を、次にどうするかで4つに分ける。送り直すか、待って読み直すか、あきらめるかは、どの経路もこの分け方だけを見て決める。
/// 経路ごとにステータスを読み分けると、429を「読めない」として二度と読まない経路が出るため、分け方はここにしか書かない。
public enum HTTPFailure: Equatable, Sendable {
    /// 待てば直る。通信の失敗、408、429、5xx、自動の通信を控えている間。`retryAfter`は、応答が示した再開までの長さ。
    case temporary(retryAfter: Duration?)
    /// 認証の失敗（401）。トークンが無効かは、セッションが確かめる。
    case unauthorized
    /// 待っても直らない。そのほかの4xx、範囲指定に応えない応答、上限を超えた応答、読めない中身。
    case permanent
    /// 質を上げると先読みの通信を、今の回線では送らないとOSが断った（`RequestPurpose`）。時間をおいては読み直さず、回線が変わって描き直したときに選び直す。
    case unavailableOnNetwork

    /// 取り消しはnil。失敗ではないので、覚えも知らせもしない。
    public init?(_ error: any Error) {
        switch error {
        case is CancellationError:
            return nil
        case let error as URLError:
            // 通信の失敗は、つながれば通る。
            guard error.code != .cancelled else { return nil }
            // `.cellular`は、端末の設定でこのアプリのモバイルデータ通信を切ったときなどにも付く。アプリが付けた制限ではないので、つながれば通る失敗にする。
            self = switch error.networkUnavailableReason {
            case .expensive?, .constrained?: .unavailableOnNetwork
            default: .temporary(retryAfter: nil)
            }
        case let error as any HTTPStatusFailure:
            self = HTTPFailure(statusCode: error.statusCode, retryAfter: error.retryAfter)
        case let error as AutomaticRequestsPaused:
            self = .temporary(retryAfter: error.retryAfter)
        default:
            self = .permanent
        }
    }

    public init(statusCode: Int, retryAfter: Duration? = nil) {
        switch statusCode {
        case 401: self = .unauthorized
        case 408, 429, 500...599: self = .temporary(retryAfter: retryAfter)
        default: self = .permanent
        }
    }

    /// 待てば直る失敗か。
    public var isTemporary: Bool {
        if case .temporary = self { true } else { false }
    }
}

/// 2xx以外のステータスで返った失敗。分け方（`HTTPFailure`）は、ステータスと再開までの長さだけを見る。
public protocol HTTPStatusFailure: Error {
    var statusCode: Int { get }
    /// 応答が示した、試し直してよくなるまでの長さ。`Retry-After`か`X-RateLimit-Reset`から読む。なければnil。
    var retryAfter: Duration? { get }
}

/// API以外のURL（画像、ファイル、fxtwitterなど）が2xx以外を返した。本文（エラーのHTMLのページなど）は渡さない。
/// 渡すと、一時的な503でも、壊れたデータとして扱われてしまうため。
public struct HTTPStatusError: HTTPStatusFailure, Equatable, Sendable {
    public let statusCode: Int
    /// Mastodonは`/media_proxy`を制限したときの429に、`X-RateLimit-Reset`だけを付ける。
    public let retryAfter: Duration?

    public init(statusCode: Int, retryAfter: Duration? = nil) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }

    init(response: HTTPURLResponse, now: Date) {
        statusCode = response.statusCode
        retryAfter = RateLimitGate.retryAfter(of: response, now: now)
    }
}

/// 応答が、用途ごとに決めた大きさ（`ResponseLimit`）を超えた。超えた時点で読むのをやめる。
public struct ResponseTooLarge: Error, Equatable, Sendable {
    public let limit: Int

    public init(limit: Int) {
        self.limit = limit
    }
}
