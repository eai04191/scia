import Foundation
import Testing
@testable import SciaCore

struct CredentialTests {
    private func credential() throws -> Credential {
        Credential(
            instance: try #require(URL(string: "https://example.social")),
            accessToken: "token",
            clientID: "client",
            clientSecret: "secret",
            accountID: "1",
            username: "alice"
        )
    }

    /// 同じサーバーのユーザーの`acct`はサーバー名を含まないため、ログインしているサーバーの名前を付ける。
    @Test func handleOfLocalAcctAddsInstanceHost() throws {
        #expect(try credential().handle(ofAcct: "bob") == "@bob@example.social")
    }

    @Test func handleOfRemoteAcctKeepsItsDomain() throws {
        #expect(try credential().handle(ofAcct: "bob@other.example") == "@bob@other.example")
    }
}
