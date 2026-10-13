import Foundation
import SciaCore
import Testing

/// アプリの権限でKeychainに保存できることを、アプリをホストにして確かめる。
struct KeychainCredentialStoreHostedTests {
    @Test func savesLoadsAndDeletesInApp() throws {
        let store = KeychainCredentialStore(service: "net.mizle.scia.tests.\(UUID().uuidString)")
        defer { try? store.delete() }
        let credential = Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client-id",
            clientSecret: "client-secret",
            accountID: "14715",
            username: "alice"
        )

        try store.save(credential)
        #expect(try store.load() == credential)

        try store.delete()
        #expect(try store.load() == nil)
    }
}
