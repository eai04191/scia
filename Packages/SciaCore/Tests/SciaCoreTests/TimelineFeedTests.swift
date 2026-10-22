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

    @Test func listReadsListTimeline() async throws {
        let (path, query) = try await requestedQuery(.list(id: "12249"))
        #expect(path == "/api/v1/timelines/list/12249")
        #expect(query.contains(URLQueryItem(name: "max_id", value: "113000000000000002")))
    }

    /// リストは`list`引数を付けて購読し、届いたイベントの`stream`欄は`["list", "<ID>"]`で見分ける。
    /// Mastodonのストリーミングサーバーは、`streamNameFromChannelName`で`[channelName, params.list]`を返す。
    @Test func listSubscribesWithListArgument() throws {
        let subscription = TimelineFeed.list(id: "12249").subscription
        #expect(try subscription.message("subscribe") == #"{"list":"12249","stream":"list","type":"subscribe"}"#)
        #expect(subscription.streamPath == ["list", "12249"])
        #expect(subscription != TimelineFeed.list(id: "13585").subscription)
    }

    /// `home`の文脈はホームとリストに当てる。既読位置はホームと通知にしかない。
    @Test func listUsesHomeFilterContextAndNoMarker() {
        #expect(TimelineFeed.list(id: "1").filterContext == .home)
        #expect(TimelineFeed.list(id: "1").marker == nil)
    }

    @Test func hashtagReadsTagTimeline() async throws {
        let (path, query) = try await requestedQuery(.hashtag(name: "scia"))
        #expect(path == "/api/v1/timelines/tag/scia")
        #expect(query.contains(URLQueryItem(name: "max_id", value: "113000000000000002")))
    }

    /// ハッシュタグは`tag`引数を付けて購読し、届いたイベントの`stream`欄は`["hashtag", "<名前>"]`で見分ける。
    /// Mastodonのストリーミングサーバーは、`streamNameFromChannelName`で、送った名前をそのまま返す。
    @Test func hashtagSubscribesWithTagArgument() throws {
        let subscription = TimelineFeed.hashtag(name: "scia").subscription
        #expect(try subscription.message("subscribe") == #"{"stream":"hashtag","tag":"scia","type":"subscribe"}"#)
        #expect(subscription.streamPath == ["hashtag", "scia"])
    }

    /// ハッシュタグは、公式のWebクライアントと同じく`public`の文脈で当てる。既読位置はない。
    @Test func hashtagUsesPublicFilterContextAndNoMarker() {
        #expect(TimelineFeed.hashtag(name: "scia").filterContext == .public)
        #expect(TimelineFeed.hashtag(name: "scia").marker == nil)
    }
}
