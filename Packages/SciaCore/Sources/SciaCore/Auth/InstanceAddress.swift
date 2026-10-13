public import Foundation

/// ユーザーが入力したインスタンスのアドレスを、`https://<host>`の形に揃える。
public enum InstanceAddress {
    public enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .empty: "インスタンスを入力してください"
            case .invalid(let input): "インスタンスのアドレスとして読めません: \(input)"
            }
        }
    }

    /// `stellaria.network`、`https://stellaria.network/`のどちらも受け付ける。httpは受け付けない。
    public static func parse(_ input: String) throws(ParseError) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), host.contains("."),
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.user == nil
        else { throw .invalid(input) }

        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host
        normalized.port = components.port
        guard let url = normalized.url else { throw .invalid(input) }
        return url
    }
}
