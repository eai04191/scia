public import Foundation

/// ログインしたアカウントの一覧と、いま使っているアカウント。
///
/// 一度に使うのは1アカウントだけで、切り替えて使う。一覧と選択を分けて持つのは、将来は複数のアカウントを同時に使えるようにするため。
@MainActor
public final class AccountRegistry {
    /// 追加した順。
    public private(set) var accounts: [Credential] = []
    public private(set) var current: Credential?

    private let storage: any CredentialStorage
    /// 並び順と選択の保存先。nilなら保存しない。
    private let defaults: UserDefaults?
    private static let orderKey = "accounts.order"
    private static let currentKey = "accounts.current"

    /// 保存されたアカウントを読む。選択していたアカウントがなければ、先頭のアカウントを使う。
    public init(storage: any CredentialStorage, defaults: UserDefaults?) throws {
        self.storage = storage
        self.defaults = defaults
        let stored = try storage.loadAll()
        let order = defaults?.stringArray(forKey: Self.orderKey) ?? []
        // 並び順にないアカウント（1アカウントだけを保存していたころから移したものなど）は、末尾にIDの順で並べる。
        accounts = stored.sorted { lhs, rhs in
            switch (order.firstIndex(of: lhs.id), order.firstIndex(of: rhs.id)) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.id < rhs.id
            }
        }
        let currentID = defaults?.string(forKey: Self.currentKey)
        current = accounts.first { $0.id == currentID } ?? accounts.first
        persist()
    }

    /// アカウントを加えて、使うアカウントにする。同じアカウントにログインし直したときは、認証情報を新しいものにする。
    public func add(_ credential: Credential) throws {
        try storage.save(credential)
        if let index = accounts.firstIndex(where: { $0.id == credential.id }) {
            accounts[index] = credential
        } else {
            accounts.append(credential)
        }
        current = credential
        persist()
    }

    /// 使うアカウントを切り替える。一覧にないアカウントなら何もしない。
    public func select(_ id: Credential.ID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        current = account
        persist()
    }

    /// アカウントを端末から消す。使っていたアカウントなら、残りの先頭に切り替える。サーバー側のトークンは失効させない。
    public func remove(_ id: Credential.ID) throws {
        try storage.delete(id: id)
        accounts.removeAll { $0.id == id }
        if current?.id == id {
            current = accounts.first
        }
        persist()
    }

    private func persist() {
        defaults?.set(accounts.map(\.id), forKey: Self.orderKey)
        defaults?.set(current?.id, forKey: Self.currentKey)
    }
}
