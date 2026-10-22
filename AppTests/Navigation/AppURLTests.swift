import Foundation
import Testing
@testable import Scia

struct AppURLTests {
    @Test(arguments: [
        ("scia://profile/Bot_testing@stellaria.network", "Bot_testing@stellaria.network"),
        ("scia://profile/@Bot_testing@stellaria.network", "Bot_testing@stellaria.network"),
        ("scia://profile/Eai", "Eai"),
    ])
    func readsProfile(_ string: String, acct: String) throws {
        let url = try #require(URL(string: string))
        #expect(AppURL(url) == .profile(acct: acct))
    }

    @Test(arguments: [
        ("scia://share?id=7E1F5C1A-3B2D-4C5E-9F60-1A2B3C4D5E6F", 0),
        ("scia://share?id=7E1F5C1A-3B2D-4C5E-9F60-1A2B3C4D5E6F&unreadable=2", 2),
    ])
    func readsShare(_ string: String, unreadableCount: Int) throws {
        let url = try #require(URL(string: string))
        let id = try #require(UUID(uuidString: "7E1F5C1A-3B2D-4C5E-9F60-1A2B3C4D5E6F"))
        #expect(AppURL(url) == .share(id: id, unreadableCount: unreadableCount))
    }

    @Test func readsCompose() throws {
        let url = try #require(URL(string: "scia://compose?text=%3E%E9%81%B8%E3%82%93%E3%81%A0%E6%96%87%0Ahttps%3A%2F%2Fexample.com%2Fa%3Fb%3Dc%26d%3De"))
        #expect(AppURL(url) == .compose(text: ">選んだ文\nhttps://example.com/a?b=c&d=e"))
    }

    /// 書き始めの本文は、送る前の文やまだ公開していないページのURLを含むので、ログに書かない。
    @Test func logsComposeWithoutText() {
        let description = AppURL.compose(text: "> 送る前の文\nhttps://example.com/private").logDescription
        #expect(!description.contains("送る前の文"))
        #expect(!description.contains("example.com"))
    }

    @Test(arguments: [
        "scia://compose",
        "scia://compose?text=",
        "scia://share",
        "scia://share?id=not-a-uuid",
        "scia://share?id=7E1F5C1A-3B2D-4C5E-9F60-1A2B3C4D5E6F&unreadable=-1",
        "scia://share?id=7E1F5C1A-3B2D-4C5E-9F60-1A2B3C4D5E6F&unreadable=x",
        "scia://profile/",
        "scia://unknown/Eai",
        "scia-debug://profile/Eai",
    ])
    func rejectsUnknownURL(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(AppURL(url) == nil)
    }
}
