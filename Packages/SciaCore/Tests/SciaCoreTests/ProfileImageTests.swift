import Foundation
import Testing
@testable import SciaCore

struct ProfileImageTests {
    private func url(_ path: String) -> URL? {
        URL(string: "https://example.com/\(path)")
    }

    @Test func usesOriginalImageAndStillImageAsPreview() throws {
        let account = Account(
            id: "1",
            username: "alice",
            acct: "alice",
            displayName: "Alice",
            avatar: url("avatar.gif"),
            avatarStatic: url("avatar.png"),
            header: url("header.gif"),
            headerStatic: url("header.png")
        )

        let avatar = try #require(account.attachment(of: .avatar))
        #expect(avatar.type == .image)
        #expect(avatar.url == url("avatar.gif"))
        #expect(avatar.previewUrl == url("avatar.png"))
        let header = try #require(account.attachment(of: .header))
        #expect(header.url == url("header.gif"))
        #expect(header.previewUrl == url("header.png"))
        #expect(avatar.id != header.id)
    }

    @Test func idsDifferBetweenAccounts() {
        let alice = Account(id: "1", username: "alice", acct: "alice", displayName: "", avatar: url("a.png"))
        let bob = Account(id: "2", username: "bob", acct: "bob", displayName: "", avatar: url("a.png"))

        #expect(alice.attachment(of: .avatar)?.id != bob.attachment(of: .avatar)?.id)
    }

    /// サーバーが片方のURLを空で返したときは、もう片方で開く。
    @Test func fallsBackToTheOtherURL() throws {
        let stillOnly = Account(id: "1", username: "a", acct: "a", displayName: "", avatar: nil, avatarStatic: url("avatar.png"), header: url("h.png"))
        let avatar = try #require(stillOnly.attachment(of: .avatar))
        #expect(avatar.url == url("avatar.png"))
        #expect(avatar.previewUrl == url("avatar.png"))

        let originalOnly = try MastodonDecoder.make().decode(Account.self, from: Data("""
        {"id":"1","username":"a","acct":"a","display_name":"","avatar":"https://example.com/avatar.png","avatar_static":"",
         "header":"","header_static":"","note":"","url":null,"fields":[],"emojis":[],"locked":false,"bot":false,
         "followers_count":0,"following_count":0,"statuses_count":0}
        """.utf8))
        #expect(originalOnly.attachment(of: .avatar)?.previewUrl == url("avatar.png"))
        #expect(originalOnly.attachment(of: .header) == nil)
    }
}
