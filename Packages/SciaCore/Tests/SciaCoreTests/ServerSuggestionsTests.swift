import Foundation
import Testing
@testable import SciaCore

struct ServerSuggestionsTests {
    private let known = ["mastodon.social", "mstdn.social", "mstdn.jp", "fosstodon.org", "social.mstdn.jp", "mstdn"]

    @Test func ordersExactThenPrefixThenContains() {
        let suggestions = ServerSuggestions(accountDomains: [], knownDomains: known)
        #expect(suggestions.suggestions(for: "mstdn", limit: 10) == ["mstdn", "mstdn.social", "mstdn.jp", "social.mstdn.jp"])
    }

    @Test func keepsActivityOrderWithinTheSameMatch() {
        let suggestions = ServerSuggestions(accountDomains: [], knownDomains: known)
        #expect(suggestions.suggestions(for: "social", limit: 10) == ["social.mstdn.jp", "mastodon.social", "mstdn.social"])
    }

    @Test func putsAccountServersFirstWithinTheSameMatch() {
        let suggestions = ServerSuggestions(accountDomains: ["MSTDN.JP"], knownDomains: known)
        #expect(suggestions.suggestions(for: "mstdn.", limit: 10) == ["mstdn.jp", "mstdn.social", "social.mstdn.jp"])
    }

    @Test func doesNotLetAccountServersJumpAheadOfBetterMatches() {
        let suggestions = ServerSuggestions(accountDomains: ["stellaria.network"], knownDomains: known)
        #expect(suggestions.suggestions(for: "st", limit: 10).first == "stellaria.network")
        #expect(suggestions.suggestions(for: "mstdn.jp", limit: 10) == ["mstdn.jp", "social.mstdn.jp"])
    }

    @Test func showsAccountServersThenActiveServersWhenEmpty() {
        let suggestions = ServerSuggestions(accountDomains: ["stellaria.network", "mstdn.jp"], knownDomains: known)
        #expect(suggestions.suggestions(for: " ", limit: 3) == ["stellaria.network", "mstdn.jp", "mastodon.social"])
    }

    @Test func limitsTheNumberOfSuggestions() {
        let suggestions = ServerSuggestions(accountDomains: [], knownDomains: known)
        #expect(suggestions.suggestions(for: "o", limit: 2) == ["mastodon.social", "mstdn.social"])
    }

    @Test(arguments: ["https://mstdn.jp/", "  MSTDN.jp", "@alice@mstdn.jp", "https://mstdn.jp/@alice"])
    func readsTheDomainOutOfWhatWasTyped(input: String) {
        let suggestions = ServerSuggestions(accountDomains: [], knownDomains: known)
        #expect(suggestions.suggestions(for: input, limit: 10) == ["mstdn.jp", "social.mstdn.jp"])
    }

    @Test func keepsThePortOfAnAccountServer() throws {
        let instance = try InstanceAddress.parse("example.social:8443")
        let address = try #require(ServerSuggestions.address(of: instance))
        #expect(address == "example.social:8443")
        #expect(try InstanceAddress.parse(address) == instance)
        let suggestions = ServerSuggestions(accountDomains: [address], knownDomains: known)
        #expect(suggestions.suggestions(for: "example", limit: 10) == ["example.social:8443"])
    }

    @Test func returnsNothingWhenNothingMatches() {
        let suggestions = ServerSuggestions(accountDomains: [], knownDomains: known)
        #expect(suggestions.suggestions(for: "example.test").isEmpty)
    }

    @Test func loadsTheBundledList() throws {
        let domains = try ServerSuggestions.loadKnownDomains()
        #expect(domains.count > 1000)
        #expect(domains.contains("mastodon.social"))
        #expect(domains.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() })
    }
}
