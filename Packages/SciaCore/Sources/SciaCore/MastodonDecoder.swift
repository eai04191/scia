import Foundation

/// Mastodon APIのJSON（snake_case、小数秒つきISO 8601日時）を読むためのデコーダー。
public enum MastodonDecoder {
    public static func make() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(string, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ISO 8601形式ではない日時です: \(string)"
            )
        }
        return decoder
    }
}
