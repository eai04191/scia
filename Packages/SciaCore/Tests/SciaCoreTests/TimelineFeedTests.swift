import Foundation
import Testing
@testable import SciaCore

struct TimelineFeedTests {
    private func makeClient(_ transport: StubTransport) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport
        )
    }

    private func requestedQuery(_ feed: TimelineFeed) async throws -> (path: String, query: [URLQueryItem]) {
        let transport = StubTransport([.json("[]", statusCode: 200)])
        _ = try await feed.page(TimelineQuery(maxID: "113000000000000002", limit: 40), from: makeClient(transport))
        let url = try #require(await transport.requests.first?.url)
        return (url.path(), URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    }

    @Test func homeReadsHomeTimeline() async throws {
        let (path, query) = try await requestedQuery(.home)
        #expect(path == "/api/v1/timelines/home")
        #expect(query.contains(URLQueryItem(name: "max_id", value: "113000000000000002")))
    }

    @Test func localReadsOnlyThisServersPublicPosts() async throws {
        let (path, query) = try await requestedQuery(.local)
        #expect(path == "/api/v1/timelines/public")
        #expect(query.contains(URLQueryItem(name: "local", value: "true")))
        #expect(query.contains(URLQueryItem(name: "max_id", value: "113000000000000002")))
        #expect(query.contains(URLQueryItem(name: "limit", value: "40")))
    }

    @Test func federatedReadsAllPublicPosts() async throws {
        let (path, query) = try await requestedQuery(.federated)
        #expect(path == "/api/v1/timelines/public")
        #expect(!query.contains { $0.name == "local" || $0.name == "remote" })
    }

    /// 206はホームの作り直しの意味なので、公開タイムラインでは作り直し中として扱わない。
    @Test func partialContentMeansRegeneratingOnlyForHome() async throws {
        let transport = StubTransport([.json("[]", statusCode: 206)])
        let page = try await TimelineFeed.local.page(TimelineQuery(limit: 40), from: makeClient(transport))
        #expect(!page.isRegenerating)
    }

    @Test func subscribesToTheMatchingStream() throws {
        #expect(try TimelineFeed.home.subscription.message("subscribe") == #"{"stream":"user","type":"subscribe"}"#)
        #expect(try TimelineFeed.local.subscription.message("subscribe") == #"{"stream":"public:local","type":"subscribe"}"#)
        #expect(try TimelineFeed.federated.subscription.message("subscribe") == #"{"stream":"public","type":"subscribe"}"#)
    }

    @Test func publicFeedsUsePublicFilterContextAndNoMarker() {
        #expect(TimelineFeed.home.filterContext == .home)
        #expect(TimelineFeed.home.marker == .home)
        for feed in [TimelineFeed.local, .federated] {
            #expect(feed.filterContext == .public)
            #expect(feed.marker == nil)
        }
    }
}
