import Foundation
import Synchronization
import Testing
import SciaTesting
@testable import SciaCore

@Suite(.scratch)
@MainActor
struct AccountRegistryTests {
    /// 読み出す順が決まらないKeychainに合わせ、保存した順と逆に返す。
    private final class MemoryStorage: CredentialStorage {
        private let items = Mutex<[Credential]>([])

        init(_ credentials: [Credential] = []) {
            items.withLock { $0 = credentials }
        }

        func loadAll() throws -> [Credential] { items.withLock { $0.reversed() } }

        func save(_ credential: Credential) throws {
            items.withLock { items in
                if let index = items.firstIndex(where: { $0.id == credential.id }) {
                    items[index] = credential
                } else {
                    items.append(credential)
                }
            }
        }

        func delete(id: Credential.ID) throws {
            items.withLock { $0.removeAll { $0.id == id } }
        }
    }

    private func credential(_ accountID: String, host: String = "example.social", token: String = "token") throws -> Credential {
        Credential(
            instance: try #require(URL(string: "https://\(host)")),
            accessToken: token,
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: accountID,
            username: "user\(accountID)"
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = TestScratch.defaults("net.mizle.scia.tests")
        return defaults
    }

    @Test func addingSelectsAndKeepsOrderAcrossLaunches() throws {
        let storage = MemoryStorage()
        let defaults = try makeDefaults()
        let registry = try AccountRegistry(storage: storage, defaults: defaults)
        #expect(registry.current == nil)

        try registry.add(try credential("1"))
        try registry.add(try credential("2"))
        try registry.add(try credential("1", host: "other.example"))
        #expect(registry.current?.instance.host() == "other.example")

        registry.select(try credential("2").id)
        let relaunched = try AccountRegistry(storage: storage, defaults: defaults)

        #expect(relaunched.accounts.map(\.handle) == ["@user1@example.social", "@user2@example.social", "@user1@other.example"])
        #expect(relaunched.current?.id == (try credential("2")).id)
    }

    @Test func loggingInAgainReplacesCredentialWithoutDuplicating() throws {
        let registry = try AccountRegistry(storage: MemoryStorage(), defaults: try makeDefaults())
        try registry.add(try credential("1", token: "old"))
        try registry.add(try credential("2"))

        try registry.add(try credential("1", token: "new"))

        #expect(registry.accounts.map(\.accessToken) == ["new", "token"])
        #expect(registry.current?.accessToken == "new")
    }

    /// ほかのアカウントにログインし直しても、使うアカウントは替えず、保存した資格情報も新しくする。
    @Test func renewingOtherAccountKeepsCurrent() throws {
        let storage = MemoryStorage()
        let defaults = try makeDefaults()
        let registry = try AccountRegistry(storage: storage, defaults: defaults)
        try registry.add(try credential("1", token: "old"))
        try registry.add(try credential("2"))

        #expect(try registry.renew(try credential("1", token: "new")))

        #expect(registry.accounts.map(\.accessToken) == ["new", "token"])
        #expect(registry.current?.accountID == "2")
        let relaunched = try AccountRegistry(storage: storage, defaults: defaults)
        #expect(relaunched.accounts.map(\.accessToken) == ["new", "token"])
        #expect(relaunched.current?.accountID == "2")
    }

    /// 使っているアカウントにログインし直したら、使うアカウントも新しい資格情報にする。
    @Test func renewingCurrentAccountUpdatesCurrent() throws {
        let registry = try AccountRegistry(storage: MemoryStorage(), defaults: try makeDefaults())
        try registry.add(try credential("1", token: "old"))

        #expect(try registry.renew(try credential("1", token: "new")))

        #expect(registry.current?.accessToken == "new")
    }

    /// ログインし直している間にログアウトしたアカウントは、戻さない。
    @Test func renewingRemovedAccountDoesNothing() throws {
        let storage = MemoryStorage()
        let registry = try AccountRegistry(storage: storage, defaults: try makeDefaults())
        try registry.add(try credential("1"))

        #expect(try registry.renew(try credential("2")) == false)

        #expect(registry.accounts.map(\.accountID) == ["1"])
        #expect(try storage.loadAll().map(\.accountID) == ["1"])
    }

    @Test func removingCurrentSwitchesToFirstRemaining() throws {
        let registry = try AccountRegistry(storage: MemoryStorage(), defaults: try makeDefaults())
        try registry.add(try credential("1"))
        try registry.add(try credential("2"))
        try registry.add(try credential("3"))

        try registry.remove(try credential("3").id)
        #expect(registry.current?.accountID == "1")

        try registry.remove(try credential("2").id)
        #expect(registry.current?.accountID == "1")

        try registry.remove(try credential("1").id)
        #expect(registry.current == nil)
        #expect(registry.accounts.isEmpty)
    }

    /// 並び順や選択を保存していない状態（1アカウントだけを保存していたころから移した直後など）でも、保存されたアカウントを使う。
    @Test func usesStoredAccountWithoutSavedSelection() throws {
        let registry = try AccountRegistry(storage: MemoryStorage([try credential("1")]), defaults: try makeDefaults())

        #expect(registry.current?.accountID == "1")
    }

    @Test func selectingUnknownAccountDoesNothing() throws {
        let registry = try AccountRegistry(storage: MemoryStorage(), defaults: try makeDefaults())
        try registry.add(try credential("1"))

        registry.select("unknown")

        #expect(registry.current?.accountID == "1")
    }
}
