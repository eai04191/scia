import Foundation
import Testing
@testable import SciaCore

struct HandleCopyItemTests {
    /// 同じサーバーの人の`acct`にはサーバー名がないので、ハンドルとサーバーにはログインしているサーバーの名前を使う。
    @Test func localAccountUsesLoggedInServer() throws {
        let url = try #require(URL(string: "https://example.social/@bob"))
        let items = HandleCopyItem.items(acct: "bob", url: url, localServer: "example.social")
        #expect(items == [
            HandleCopyItem(kind: .handle, value: "@bob@example.social"),
            HandleCopyItem(kind: .username, value: "bob"),
            HandleCopyItem(kind: .server, value: "example.social"),
            HandleCopyItem(kind: .link, value: "https://example.social/@bob"),
        ])
    }

    @Test func remoteAccountKeepsItsServer() throws {
        let url = try #require(URL(string: "https://other.example/@carol"))
        let items = HandleCopyItem.items(acct: "carol@other.example", url: url, localServer: "example.social")
        #expect(items.map(\.value) == ["@carol@other.example", "carol", "other.example", "https://other.example/@carol"])
    }

    @Test func omitsLinkWithoutProfileURL() {
        let items = HandleCopyItem.items(acct: "bob", url: nil, localServer: "example.social")
        #expect(items.map(\.kind) == [.handle, .username, .server])
    }
}
