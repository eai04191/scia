// iOSシミュレーターでは、SciaCoreTestsはホストアプリなしで動くためKeychainの権限がなく、
// SecItemがerrSecMissingEntitlement（-34018）を返す。iOSでの動作はアプリをホストにしたSciaTestsで確かめる。
#if os(macOS)
import Foundation
import Testing
@testable import SciaCore

struct KeychainCredentialStoreTests {
    private func makeCredential(accountID: String = "14715", token: String) throws -> Credential {
        Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: token,
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: accountID,
            username: "alice"
        )
    }

    @Test func savesEachAccountOverwritesAndDeletes() throws {
        let store = KeychainCredentialStore(service: "net.mizle.scia.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }

        #expect(try store.loadAll().isEmpty)

        let alice = try makeCredential(token: "first")
        let bob = try makeCredential(accountID: "2", token: "bob")
        try store.save(alice)
        try store.save(bob)
        #expect(Set(try store.loadAll().map(\.accessToken)) == ["first", "bob"])

        try store.save(try makeCredential(token: "second"))
        #expect(Set(try store.loadAll().map(\.accessToken)) == ["second", "bob"])

        try store.delete(id: bob.id)
        #expect(try store.loadAll().map(\.accessToken) == ["second"])
        try store.delete(id: bob.id)
    }

    /// 1アカウントだけを保存していたころの項目は、読み出すときにアカウントごとの項目へ移す。ログインし直さずに済むようにするため。
    @Test func migratesLegacySingleItem() throws {
        let store = KeychainCredentialStore(service: "net.mizle.scia.tests.\(UUID().uuidString)")
        defer { try? store.deleteAll() }
        let legacy = try makeCredential(token: "legacy")
        try store.saveLegacy(legacy)

        #expect(try store.loadAll() == [legacy])
        // 移した後は古い項目が残らず、2回目に読んでも重複しない。
        #expect(try store.loadAll() == [legacy])
        try store.delete(id: legacy.id)
        #expect(try store.loadAll().isEmpty)
    }
}
#endif
