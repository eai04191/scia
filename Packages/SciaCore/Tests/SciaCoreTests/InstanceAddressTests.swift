import Foundation
import Testing
@testable import SciaCore

struct InstanceAddressTests {
    @Test(arguments: [
        "stellaria.network",
        " stellaria.network ",
        "Stellaria.Network",
        "https://stellaria.network",
        "https://stellaria.network/",
    ])
    func normalizesToHTTPSHost(input: String) throws {
        #expect(try InstanceAddress.parse(input).absoluteString == "https://stellaria.network")
    }

    @Test func keepsPort() throws {
        #expect(try InstanceAddress.parse("localhost.test:3000").absoluteString == "https://localhost.test:3000")
    }

    @Test func rejectsEmpty() {
        #expect(throws: InstanceAddress.ParseError.empty) { try InstanceAddress.parse("  ") }
    }

    @Test(arguments: ["http://stellaria.network", "stellaria.network/about", "stellaria", "user@stellaria.network"])
    func rejectsInvalid(input: String) {
        #expect(throws: InstanceAddress.ParseError.invalid(input)) { try InstanceAddress.parse(input) }
    }
}
