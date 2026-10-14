public import Foundation
import Security

/// ログインしたアカウントの認証情報を保存する口。テストではメモリ上の実装に差し替える。
public protocol CredentialStorage: Sendable {
    /// 順は決まらない。並べる順は呼び出し側で持つ。
    func loadAll() throws -> [Credential]
    /// 同じアカウントがあれば上書きする。
    func save(_ credential: Credential) throws
    func delete(id: Credential.ID) throws
}

/// 認証情報を、アカウントごとに1件ずつKeychainへ保存する。
public struct KeychainCredentialStore: CredentialStorage {
    public enum KeychainError: Error, Equatable, LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status): "Keychainの操作に失敗しました（\(status)）"
            }
        }
    }

    private let service: String
    /// 1アカウントだけを保存していたころの項目の名前。読み出すときに、アカウントごとの項目へ移す。
    private static let legacyAccount = "current"

    public init(service: String) {
        self.service = service
    }

    public func loadAll() throws -> [Credential] {
        try migrateLegacyItem()
        // macOSの従来のKeychainは、データを返す検索で複数件を求めるとerrSecParamを返すため、名前を一覧してから1件ずつ読む。
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else { throw KeychainError.unexpectedStatus(errSecDecode) }
            return try items.compactMap { $0[kSecAttrAccount as String] as? String }.compactMap(load(account:))
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func save(_ credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)
        let query = itemQuery(account: credential.id)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            // バックグラウンドからの復帰時にも読めるよう、初回のロック解除以降は読めるようにする。
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func delete(id: Credential.ID) throws {
        try deleteItem(account: id)
    }

    /// このサービスの項目をすべて消す。テストの後片付けに使う。
    public func deleteAll() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 1アカウントだけを保存していたころの項目があれば、アカウントごとの項目に保存し直して消す。
    private func migrateLegacyItem() throws {
        guard let legacy = try load(account: Self.legacyAccount) else { return }
        try save(legacy)
        try deleteItem(account: Self.legacyAccount)
    }

    /// 1件を読む。なければnil。
    private func load(account: String) throws -> Credential? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedStatus(errSecDecode) }
            return try JSONDecoder().decode(Credential.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 移す前の形式で保存する。移行のテストにだけ使う。
    func saveLegacy(_ credential: Credential) throws {
        var attributes = itemQuery(account: Self.legacyAccount)
        attributes[kSecValueData as String] = try JSONEncoder().encode(credential)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private func deleteItem(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    private func itemQuery(account: String) -> [String: Any] {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        return query
    }
}
