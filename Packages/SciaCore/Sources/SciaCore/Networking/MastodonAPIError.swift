public import Foundation

/// Mastodon APIが2xx以外を返したときのエラー。
public struct MastodonAPIError: Error, Equatable, LocalizedError {
    public let statusCode: Int
    /// レスポンスの`error`と`error_description`。JSONでなければ本文をそのまま入れる。記録に使い、画面には出さない。
    public let message: String
    /// サーバーがJSONで返した理由。HTMLのエラーページなどJSONでなければnil。理由をそのまま見せる失敗（文字数の超過など）に使う。
    public let serverMessage: String?

    public init(statusCode: Int, message: String, serverMessage: String? = nil) {
        self.statusCode = statusCode
        self.message = message
        self.serverMessage = serverMessage
    }

    public var errorDescription: String? {
        "サーバーがエラーを返しました（\(statusCode)）: \(message)"
    }

    static func from(statusCode: Int, body: Data) -> MastodonAPIError {
        struct Body: Decodable {
            let error: String
            let errorDescription: String?
        }
        if let body = try? MastodonDecoder.make().decode(Body.self, from: body) {
            let message = [body.error, body.errorDescription].compactMap(\.self).joined(separator: ": ")
            return MastodonAPIError(statusCode: statusCode, message: message, serverMessage: message)
        }
        return MastodonAPIError(statusCode: statusCode, message: String(decoding: body, as: UTF8.self))
    }
}
