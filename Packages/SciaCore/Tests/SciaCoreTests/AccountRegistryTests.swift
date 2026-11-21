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

    /// 並べ替えた順は、起動し直しても残り、使っているアカウントは替えない。位置はSwiftUIの`onMove`と同じく、動かす前の並びで数える。
    @Test(arguments: [
        (source: [0], destination: 3, expected: ["2", "3", "1"]),
        (source: [2], destination: 0, expected: ["3", "1", "2"]),
        (source: [0, 2], destination: 2, expected: ["2", "1", "3"]),
        (source: [1], destination: 1, expected: ["1", "2", "3"]),
    ])
    func movingKeepsOrderAcrossLaunches(source: [Int], destination: Int, expected: [String]) throws {
        let storage = MemoryStorage()
        let defaults = try makeDefaults()
        let registry = try AccountRegistry(storage: storage, defaults: defaults)
        for id in ["1", "2", "3"] {
            try registry.add(try credential(id))
        }
        registry.select(try credential("2").id)

        registry.move(fromOffsets: IndexSet(source), toOffset: destination)
        let relaunched = try AccountRegistry(storage: storage, defaults: defaults)

        #expect(registry.accounts.map(\.accountID) == expected)
        #expect(relaunched.accounts.map(\.accountID) == expected)
        #expect(relaunched.current?.accountID == "2")
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
