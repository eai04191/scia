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

    @Test(arguments: [
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
