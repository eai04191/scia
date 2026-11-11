import Foundation

/// 失敗を使う人に見せる形。種類ごとに決めた文言と、調べるときのために小さく添える補足（ステータスコードなど）に分ける。
///
/// HTMLのエラーページの本文や`DecodingError`の文は、使う人には意味がないため出さない。
/// アプリが自分で作った`LocalizedError`（「見つかりませんでした」など）は、その文言をそのまま出す。
///
/// 文言は、アプリの失敗を出す部品（`FailureDisplay`）だけが読めるよう、SPIにする。部品を通さずに文言だけを出すと、ログアウトされたときのログインし直すボタンが付かないため。
public struct ErrorPresentation: Hashable, Sendable {
    @_spi(FailureDisplay) public let message: String
    /// 小さく添える補足。「HTTP 503」「URLError -1009」など。
    @_spi(FailureDisplay) public let code: String?
    /// ログアウトされたアカウント。理由を見せるところは、そのアカウントでログインし直すボタンを添える。
    public let loggedOutAccount: RequestAccount?

    public init(message: String, code: String?, loggedOutAccount: RequestAccount? = nil) {
        self.message = message
        self.code = code
        self.loggedOutAccount = loggedOutAccount
    }

    public init(_ error: any Error) {
        switch error {
        case let error as any HTTPStatusFailure:
            let apiError = error as? MastodonAPIError
            self = Self.presentation(statusCode: error.statusCode, serverMessage: apiError?.serverMessage, account: apiError?.account)
        case is ResponseTooLarge:
            self.init(message: "サーバーから届いた内容が大きすぎるため、読むのをやめました。", code: nil)
        case let error as URLError:
            self = Self.presentation(of: error)
        case let error as AutomaticRequestsPaused:
            // 再開の時刻になったら、失敗した読み込みはアプリがやり直す。
            self.init(message: "短い間にリクエストが多すぎたため、サーバーに一時的に止められています。\(error.until.formatted(date: .omitted, time: .shortened))を過ぎたら自動で読み込み直します。", code: nil)
        case is DecodingError:
            self.init(message: "サーバーから届いた内容を読めませんでした。", code: nil)
        default:
            self.init(message: error.localizedDescription, code: nil)
        }
    }

    /// 何が起きたかの一文を、理由の前に置いたもの。ログアウトされたアカウントは残す。
    public func leading(_ lead: String) -> ErrorPresentation {
        ErrorPresentation(message: "\(lead)\n\(text)", code: nil, loggedOutAccount: loggedOutAccount)
    }

    /// 補足を括弧で添えて1行にしたもの。アラートなど、補足だけを小さく出せないところで使う。
    @_spi(FailureDisplay) public var text: String {
        code.map { "\(message)（\($0)）" } ?? message
    }

    /// - Parameter serverMessage: REST APIがJSONで返した理由。API以外の通信ではnil。
    /// - Parameter account: 通信を送ったアカウント。401なら、ログインし直すボタンのために持つ。「別のアカウントで」使うほかのアカウントなら、どのアカウントがログアウトされているかを出す。
    ///   今使っているアカウントなら、どのアカウントかは分かるので、ハンドルは出さない。
    private static func presentation(statusCode: Int, serverMessage: String?, account: RequestAccount?) -> Self {
        // MastodonのREST APIは、トークンが無効なときだけ401を返す（`AuthorizationCheck`）。
        // アカウントの付かない401（ログイン画面の通信、画像やファイルのホスト）は、ログアウトではないので、403と同じ文にする。
        if statusCode == 401, let account {
            let message = account.isOtherAccount ? "\(account.handle)はログアウトされています。" : "ログアウトされています。"
            return Self(message: message, code: "HTTP 401", loggedOutAccount: account)
        }
        let message = switch statusCode {
        case 401, 403: "アクセスが拒否されました。"
        case 404, 410, 501: "見つからないか、このサーバーでは使えません。"
        case 429: "短い間にリクエストが多すぎたため、サーバーに一時的に止められています。しばらくしてからもう一度お試しください。"
        case 500..<600: "サーバーが一時的に応答できません。しばらくしてからもう一度お試しください。"
        // 文字数の超過など、理由がJSONで返る失敗は、その理由がいちばん役に立つ。
        default: serverMessage ?? "サーバーがリクエストを受け付けませんでした。"
        }
        return Self(message: message, code: "HTTP \(statusCode)")
    }

    private static func presentation(of error: URLError) -> Self {
        let message = switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            "インターネットに接続できません。"
        case .timedOut:
            "サーバーから時間内に応答がありませんでした。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            "サーバーに接続できませんでした。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            "サーバーと安全に接続できませんでした。"
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData, .zeroByteResource:
            "サーバーから届いた内容を読めませんでした。"
        default:
            "通信できませんでした。"
        }
        return Self(message: message, code: "URLError \(error.code.rawValue)")
    }
}
