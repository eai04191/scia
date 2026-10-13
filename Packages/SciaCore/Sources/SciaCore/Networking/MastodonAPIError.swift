public import Foundation

/// Mastodon APIが2xx以外を返したときのエラー。
public struct MastodonAPIError: Error, Equatable, LocalizedError {
    public let statusCode: Int
    /// レスポンスの`error`と`error_description`。JSONでなければ本文をそのまま入れる。
    public let message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
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
            return MastodonAPIError(statusCode: statusCode, message: message)
        }
        return MastodonAPIError(statusCode: statusCode, message: String(decoding: body, as: UTF8.self))
    }
}
