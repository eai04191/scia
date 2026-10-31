import Testing
@testable import SciaCore

struct UserHandleTests {
    /// 同じサーバーの人の`acct`にはサーバー名がないので、ログインしているサーバーの名前を補う。
    @Test func localAccountUsesLoggedInServer() {
        let handle = UserHandle(acct: "bob", localServer: "example.social")
        #expect([handle.text(of: .handle), handle.text(of: .username), handle.text(of: .server)] == ["@bob@example.social", "bob", "example.social"])
    }

    @Test func remoteAccountKeepsItsServer() {
        let handle = UserHandle(acct: "carol@other.example", localServer: "example.social")
        #expect([handle.text(of: .handle), handle.text(of: .username), handle.text(of: .server)] == ["@carol@other.example", "carol", "other.example"])
    }
}
