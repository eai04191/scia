public import Foundation
public import Observation

/// ログインしたアカウントのリストと、いま使っているアカウント。
///
/// 一度に使うのは1アカウントだけで、切り替えて使う。リストと選択を分けて持つのは、将来は複数のアカウントを同時に使えるようにするため。
@MainActor
@Observable
public final class AccountRegistry {
    /// 使う人が並べた順。並べ替えていなければ、追加した順。
    public private(set) var accounts: [Credential] = []
    public private(set) var current: Credential?

    @ObservationIgnored private let storage: any CredentialStorage
    /// 並び順と選択の保存先。nilなら保存しない。
    @ObservationIgnored private let defaults: UserDefaults?
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

    /// ログインし直したアカウントの認証情報を新しくする。使うアカウントは替えない。
    /// ほかのアカウントにログインし直したときに、今のアカウントのまま使い続けるため。
    /// - Returns: リストにあって新しくしたか。ログインし直している間にログアウトしたアカウントは、戻さずにfalseを返す。
    @discardableResult
    public func renew(_ credential: Credential) throws -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == credential.id }) else { return false }
        try storage.save(credential)
        accounts[index] = credential
        if current?.id == credential.id {
            current = credential
        }
        persist()
        return true
    }

    /// 使うアカウントを切り替える。リストにないアカウントなら何もしない。
    public func select(_ id: Credential.ID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        current = account
        persist()
    }

    /// `source`の位置のアカウントを、動かす前の並びで`destination`の位置の前へ動かす。SwiftUIの`onMove`が渡す位置をそのまま受け取る。
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter(accounts.indices.contains).map { accounts[$0] }
        var remaining = accounts.indices.filter { !source.contains($0) }.map { accounts[$0] }
        let insertion = min(destination - source.count { $0 < destination }, remaining.count)
        remaining.insert(contentsOf: moving, at: max(insertion, 0))
        accounts = remaining
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
