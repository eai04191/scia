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
        "scia://profile/",
        "scia://unknown/Eai",
        "scia-debug://profile/Eai",
    ])
    func rejectsUnknownURL(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(AppURL(url) == nil)
    }
}
