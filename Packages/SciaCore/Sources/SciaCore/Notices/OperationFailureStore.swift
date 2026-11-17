public import Foundation

/// 「操作の状況」の最近の失敗を、アカウントごとにUserDefaultsへ保存する。キーは`AccountScopedDefaults`で作り、ログアウトで消す。
/// 同じアカウントを複数のウインドウで開いても上書きし合わないよう、`OperationStatus`は書く前に読み直す。
public struct OperationFailureStore {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter account: ログインしているアカウントのハンドル（`Credential.handle`）。
    public init(defaults: UserDefaults, account: String) {
        self.defaults = defaults
        key = AccountScopedDefaults.key("operationFailures", account: account)
    }

    /// 新しい順。
    func load() -> [OperationStatus.Failure] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([OperationStatus.Failure].self, from: data)) ?? []
    }

    func save(_ failures: [OperationStatus.Failure]) {
        guard let data = try? JSONEncoder().encode(failures) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 理由のうち、ログインし直すボタンのためのアカウントは保存しない。読み戻すころにはログインし直していることがあり、古い行にボタンが残るため。
extension OperationStatus.Failure: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, message, code, subject, date
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            reason: ErrorPresentation(message: try container.decode(String.self, forKey: .message), code: try container.decodeIfPresent(String.self, forKey: .code)),
            subject: try container.decodeIfPresent(OperationStatus.Subject.self, forKey: .subject),
            date: try container.decode(Date.self, forKey: .date)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(reason.message, forKey: .message)
        try container.encodeIfPresent(reason.code, forKey: .code)
        try container.encodeIfPresent(subject, forKey: .subject)
        try container.encode(date, forKey: .date)
    }
}
