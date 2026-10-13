// iOSシミュレーターでは、SciaCoreTestsはホストアプリなしで動くためKeychainの権限がなく、
// SecItemがerrSecMissingEntitlement（-34018）を返す。iOSでの動作はアプリをホストにしたSciaTestsで確かめる。
#if os(macOS)
import Foundation
import Testing
@testable import SciaCore

struct KeychainCredentialStoreTests {
    private func makeCredential(token: String) throws -> Credential {
        Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: token,
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "14715",
            username: "alice"
        )
    }

    @Test func savesLoadsOverwritesAndDeletes() throws {
        let store = KeychainCredentialStore(service: "net.mizle.scia.tests.\(UUID().uuidString)")
        defer { try? store.delete() }

        #expect(try store.load() == nil)

        let first = try makeCredential(token: "first")
        try store.save(first)
        #expect(try store.load() == first)

        let second = try makeCredential(token: "second")
        try store.save(second)
        #expect(try store.load() == second)

        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }
}
#endif
