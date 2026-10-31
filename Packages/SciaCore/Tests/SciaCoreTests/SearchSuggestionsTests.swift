import Foundation
import SciaTesting
import Testing
@testable import SciaCore

@MainActor
@Suite(.serialized, .scratch)
struct SearchSuggestionsTests {
    private static let settings = ComposeCompletion.Settings(debounce: .milliseconds(200), limit: 4, minimumSearchQueryLength: 2)

    /// ユーザーの検索には1人、ハッシュタグの検索には1つを返す。
    nonisolated private static func transport() -> RoutedTransport {
        RoutedTransport { request in
            if request.url?.path() == "/api/v1/accounts/search" {
                let url = try #require(Bundle.module.url(forResource: "account", withExtension: "json", subdirectory: "Fixtures"))
                return (200, Data("[\(try String(contentsOf: url, encoding: .utf8))]".utf8))
            }
            return (200, Data(#"{"accounts":[],"statuses":[],"hashtags":[{"name":"neko","url":"https://example.social/tags/neko","history":[]}]}"#.utf8))
        }
    }

    private func make(transport: RoutedTransport = transport(), clock: TestClock = TestClock()) -> (SearchSuggestions, RecentSearches) {
        let recents = RecentSearches(defaults: TestScratch.defaults("SearchSuggestionsTests"), account: "@me@example.social")
        let client = MastodonClient(credential: TimelineModelFixtures.credential(), transport: transport)
        return (SearchSuggestions(client: client, recents: recents, settings: Self.settings, clock: clock, tasks: TaskScope()), recents)
    }

    /// 語の形に応じた行を、すぐに出す。URLでは、ユーザーとハッシュタグを探さない。
    @Test func actionsFollowInputShape() throws {
        let transport = Self.transport()
        let (suggestions, _) = make(transport: transport)
        defer { suggestions.stop() }

        suggestions.update(" 猫 ")
        #expect(suggestions.content.actions == [.search("猫")])
        suggestions.update("@bob@remote.example")
        #expect(suggestions.content.actions == [.openHandle(acct: "bob@remote.example"), .search("@bob@remote.example")])
        suggestions.update("#neko")
        #expect(suggestions.content.actions == [.openHashtag(name: "neko"), .search("#neko")])
        let url = try #require(URL(string: "https://remote.example/@bob/1"))
        suggestions.update("https://remote.example/@bob/1")
        #expect(suggestions.content.actions == [.openURL(url), .search("https://remote.example/@bob/1")])
        #expect(transport.requests.isEmpty)
    }

    /// ユーザーとハッシュタグは、間をおいてから探す。間の途中で打ち直したら、前の語では探さない。
    @Test func looksUpAfterDebounceAndOnlyLatest() async throws {
        let clock = TestClock()
        let transport = Self.transport()
        let (suggestions, _) = make(transport: transport, clock: clock)
        defer { suggestions.stop() }

        suggestions.update("ne")
        try await waitUntil { clock.sleeperCount(dueWithin: .milliseconds(200)) == 1 }
        suggestions.update("nek")
        try await waitUntil { clock.sleeperCount(dueWithin: .milliseconds(200)) == 1 }
        clock.advance(by: .milliseconds(200))
        try await waitUntil { suggestions.runningTaskCount == 0 }

        #expect(suggestions.content.accounts.map(\.id) == ["2"])
        #expect(suggestions.content.hashtags.map(\.name) == ["neko"])
        let queries = transport.requests.compactMap { $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value } }
        #expect(Set(queries) == ["nek"])
    }

    /// サーバーで探す文字数に届かなければ、探さずに前の候補も消す。
    @Test func shortQueryDoesNotLookUp() async throws {
        let transport = Self.transport()
        let (suggestions, _) = make(transport: transport)
        defer { suggestions.stop() }

        suggestions.update("n")
        #expect(suggestions.runningTaskCount == 0)
        #expect(suggestions.content.accounts.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    /// 語が空なら、最近の検索を出す。確定した語は先頭に足し、同じ語は先頭へ動かす。
    @Test func emptyShowsRecents() {
        let (suggestions, recents) = make()
        defer { suggestions.stop() }

        suggestions.submit("猫")
        suggestions.submit("犬")
        suggestions.submit(" 猫 ")
        suggestions.update("")
        #expect(suggestions.content == SearchSuggestions.Content(recents: ["猫", "犬"]))

        suggestions.removeRecent("猫")
        #expect(suggestions.content.recents == ["犬"])
        suggestions.removeAllRecents()
        #expect(suggestions.content.recents.isEmpty)
        #expect(recents.queries.isEmpty)
    }

    /// 覚えておくのは20件まで。
    @Test func recentsAreCapped() {
        let (_, recents) = make()
        for number in 0..<25 {
            recents.record("\(number)")
        }
        #expect(recents.queries.count == RecentSearches.capacity)
        #expect(recents.queries.first == "24")
    }
}
