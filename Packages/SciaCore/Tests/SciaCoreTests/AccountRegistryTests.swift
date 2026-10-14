import Foundation
import Synchronization
import Testing
@testable import SciaCore

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
        let name = "net.mizle.scia.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
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
