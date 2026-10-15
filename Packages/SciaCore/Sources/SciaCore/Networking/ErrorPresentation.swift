import Foundation

/// 失敗を使う人に見せる形。種類ごとに決めた文言と、調べるときのために小さく添える補足（ステータスコードなど）に分ける。
///
/// HTMLのエラーページの本文や`DecodingError`の文は、使う人には意味がないため出さない。
/// アプリが自分で作った`LocalizedError`（「見つかりませんでした」など）は、その文言をそのまま出す。
public struct ErrorPresentation: Equatable, Sendable {
    public let message: String
    /// 小さく添える補足。「HTTP 503」「URLError -1009」など。
    public let code: String?

    public init(message: String, code: String?) {
        self.message = message
        self.code = code
    }

    public init(_ error: any Error) {
        switch error {
        case let error as MastodonAPIError:
            self = Self.presentation(of: error)
        case let error as URLError:
            self = Self.presentation(of: error)
        case is DecodingError:
            self.init(message: "サーバーから届いた内容を読めませんでした。", code: nil)
        default:
            self.init(message: error.localizedDescription, code: nil)
        }
    }

    /// 補足を括弧で添えて1行にしたもの。アラートなど、補足だけを小さく出せないところで使う。
    public var text: String {
        code.map { "\(message)（\($0)）" } ?? message
    }

    private static func presentation(of error: MastodonAPIError) -> Self {
        let message = switch error.statusCode {
        case 401: "サーバーがログインを受け付けませんでした。"
        case 403: "サーバーがこの操作を許可しませんでした。"
        case 404, 410, 501: "見つからないか、このサーバーでは使えません。"
        case 429: "短い間にリクエストが多すぎたため、サーバーに一時的に止められています。しばらく待ってからやり直してください。"
        case 500..<600: "サーバーが一時的に応答できません。しばらく待ってからやり直してください。"
        // 文字数の超過など、理由がJSONで返る失敗は、その理由がいちばん役に立つ。
        default: error.serverMessage ?? "サーバーがリクエストを受け付けませんでした。"
        }
        return Self(message: message, code: "HTTP \(error.statusCode)")
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
