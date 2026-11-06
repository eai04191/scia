public import Foundation

/// Mastodon APIが2xx以外を返したときのエラー。
public struct MastodonAPIError: HTTPStatusFailure, Equatable, LocalizedError {
    public let statusCode: Int
    /// レスポンスの`error`と`error_description`。JSONでなければ本文をそのまま入れる。記録に使い、画面には出さない。
    public let message: String
    /// サーバーがJSONで返した理由。HTMLのエラーページなどJSONでなければnil。理由をそのまま見せる失敗（文字数の超過など）に使う。
    public let serverMessage: String?
    /// 429や503の応答が示した、再開までの長さ。示していなければnil。
    public let retryAfter: Duration?
    /// 断られた通信を送ったアカウント。`MastodonClient`が入れる。401なら、そのアカウントがログアウトされている。
    public internal(set) var account: RequestAccount?

    public init(statusCode: Int, message: String, serverMessage: String? = nil, retryAfter: Duration? = nil, account: RequestAccount? = nil) {
        self.statusCode = statusCode
        self.message = message
        self.serverMessage = serverMessage
        self.retryAfter = retryAfter
        self.account = account
    }

    public var errorDescription: String? {
        "サーバーがエラーを返しました（\(statusCode)）: \(message)"
    }

    static func from(statusCode: Int, body: Data, retryAfter: Duration? = nil) -> MastodonAPIError {
        struct Body: Decodable {
            let error: String
            let errorDescription: String?
        }
        if let body = try? MastodonDecoder.make().decode(Body.self, from: body) {
            let message = [body.error, body.errorDescription].compactMap(\.self).joined(separator: ": ")
            return MastodonAPIError(statusCode: statusCode, message: message, serverMessage: message, retryAfter: retryAfter)
        }
        return MastodonAPIError(statusCode: statusCode, message: String(decoding: body, as: UTF8.self), retryAfter: retryAfter)
    }
}

/// 通信を送ったアカウント。失敗から、そのアカウントでログインし直せるようにする。トークンは持たない。
public struct RequestAccount: Hashable, Sendable {
    public let id: Credential.ID
    /// 使う人に見せるハンドル（`@username@server`）。
    public let handle: String
    /// 「別のアカウントで」使う、今使っているアカウントとは別のアカウントか。そうなら、理由にどのアカウントかを出す。
    public let isOtherAccount: Bool

    public init(id: Credential.ID, handle: String, isOtherAccount: Bool = false) {
        self.id = id
        self.handle = handle
        self.isOtherAccount = isOtherAccount
    }

    public init(_ credential: Credential, isOtherAccount: Bool) {
        self.init(id: credential.id, handle: credential.handle, isOtherAccount: isOtherAccount)
    }
}
