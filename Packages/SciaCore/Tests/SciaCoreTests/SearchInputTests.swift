import Foundation
import Testing
@testable import SciaCore

struct SearchInputTests {
    /// 前後の空白を除き、URL、ハンドル、ハッシュタグ、ほかの語を見分ける。
    @Test(arguments: [
        ("  猫  ", SearchInput.text("猫")),
        ("@alice@example.social", .handle(acct: "alice@example.social")),
        ("alice@example.social", .handle(acct: "alice@example.social")),
        ("a.b_c-d@sub.example.social", .handle(acct: "a.b_c-d@sub.example.social")),
        ("#猫", .hashtag(name: "猫")),
        ("from:me 猫", .text("from:me 猫")),
        // ドメインのない`@`だけの名前と、メールアドレスに見えない文は、語として探す。
        ("@alice", .text("@alice")),
        ("猫@家", .text("猫@家")),
        ("alice@localhost", .text("alice@localhost")),
        ("#", .text("#")),
        ("#猫 #犬", .text("#猫 #犬")),
    ])
    func classifies(_ text: String, _ expected: SearchInput) {
        #expect(SearchInput(text) == expected)
    }

    @Test func emptyIsNil() {
        #expect(SearchInput("   ") == nil)
    }

    /// Mastodonは小文字のスキームのときだけURLとして読み込むため、スキームを小文字にして送る。ホストのないものはURLにしない。
    @Test func urlLowercasesScheme() throws {
        let input = try #require(SearchInput("HTTPS://example.social/@alice/1"))
        #expect(input.query == "https://example.social/@alice/1")
        #expect(SearchInput("https://") == .text("https://"))
        #expect(SearchInput("ftp://example.social/x") == .text("ftp://example.social/x"))
    }

    /// 同じサーバーのユーザーの`acct`はサーバー名を含まないため、ログインしているサーバーの名前を付けて比べる。大文字と小文字は区別しない。
    @Test func handleNamesAccount() throws {
        let credential = Credential(instance: try #require(URL(string: "https://home.example")), accessToken: "t", clientID: "c", clientSecret: "s", accountID: "1", username: "me")
        let avatar = try #require(URL(string: "https://home.example/a.png"))
        let local = Account(id: "2", username: "alice", acct: "alice", displayName: "", avatar: avatar)
        let remote = Account(id: "3", username: "Bob", acct: "Bob@remote.example", displayName: "", avatar: avatar)

        #expect(try #require(SearchInput("@alice@home.example")).names(local, on: credential))
        #expect(try #require(SearchInput("bob@REMOTE.example")).names(remote, on: credential))
        #expect(try #require(SearchInput("alice@remote.example")).names(local, on: credential) == false)
        #expect(try #require(SearchInput("alice")).names(local, on: credential) == false)
    }
}
