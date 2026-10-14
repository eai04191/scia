import Foundation
import Testing
@testable import SciaCore

struct MastodonClientTests {
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

    @Test func homeTimelineDecodesStatusesAndReblogs() async throws {
        let transport = StubTransport([try .fixture("home_timeline")])

        let page = try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40))

        #expect(!page.isRegenerating)
        #expect(page.statuses.map(\.id) == ["113000000000000003", "113000000000000002"])
        let boost = try #require(page.statuses.first)
        #expect(boost.account.username == "bob")
        #expect(boost.reblog?.id == "113000000000000001")
        let original = try #require(boost.reblog)
        #expect(original.mentions.map(\.acct) == ["bob@remote.example"])
        #expect(original.tags.map(\.name) == ["scia"])
        #expect(original.emojis.map(\.shortcode) == ["blobcat"])
        #expect(original.account.emojis.map(\.staticUrl.lastPathComponent) == ["blobcat.png"])
        #expect(RichText.status(original).plainText == "@bob ブーストされた投稿 :blobcat: #scia")
        #expect(page.statuses[1].reblog == nil)
        #expect(page.statuses[1].displayed.id == "113000000000000002")
    }

    @Test func homeTimelineSendsPagingQueryAndToken() async throws {
        let transport = StubTransport([.json("[]", statusCode: 200)])

        _ = try await makeClient(transport).homeTimeline(TimelineQuery(maxID: "113000000000000002", sinceID: "113000000000000000", minID: "113000000000000001", limit: 40))

        let request = try #require(await transport.requests.first)
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path() == "/api/v1/timelines/home")
        #expect(query.contains(URLQueryItem(name: "max_id", value: "113000000000000002")))
        #expect(query.contains(URLQueryItem(name: "since_id", value: "113000000000000000")))
        #expect(query.contains(URLQueryItem(name: "min_id", value: "113000000000000001")))
        #expect(query.contains(URLQueryItem(name: "limit", value: "40")))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func homeTimelineOmitsMaxIDForLatestPage() async throws {
        let transport = StubTransport([.json("[]", statusCode: 200)])

        _ = try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40))

        let url = try #require(await transport.requests.first?.url)
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        #expect(names == ["limit"])
    }

    @Test func partialContentMeansRegenerating() async throws {
        let transport = StubTransport([.json("[]", statusCode: 206)])

        let page = try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40))

        #expect(page.isRegenerating)
        #expect(page.statuses.isEmpty)
    }

    @Test func unauthorizedIsReported() async throws {
        let transport = StubTransport([.json(#"{"error":"The access token is invalid"}"#, statusCode: 401)])

        let error = await #expect(throws: MastodonAPIError.self) {
            _ = try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40))
        }
        #expect(error?.isUnauthorized == true)
        #expect(error?.message == "The access token is invalid")
    }

    @Test func notificationsDecodeKnownAndUnknownTypes() async throws {
        let transport = StubTransport([try .fixture("notifications")])

        let notifications = try await makeClient(transport).notifications(TimelineQuery(maxID: "34975870", limit: 40))

        #expect(notifications.map(\.id) == ["34975864", "34975863", "34975862", "34975861"])
        #expect(notifications.map(\.type) == [.other("admin.sign_up"), .mention, .follow, .favourite])
        #expect(notifications[0].account.displayNameOrUsername == "dave")
        #expect(notifications[1].status?.mentions.map(\.acct) == ["alice"])
        #expect(notifications[2].status == nil)
        #expect(notifications[2].account.emojis.map(\.shortcode) == ["blobcat"])
        #expect(notifications[3].status?.id == "113000000000000001")
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/notifications")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "max_id", value: "34975870")))
        #expect(query.contains(URLQueryItem(name: "limit", value: "40")))
    }

    @Test func notificationsMarkerUsesNotificationsTimeline() async throws {
        let transport = StubTransport([
            .json(#"{"notifications":{"last_read_id":"34975862","version":1,"updated_at":"2026-10-13T03:21:45.123Z"}}"#, statusCode: 200),
            .json(#"{"notifications":{"last_read_id":"34975864","version":2,"updated_at":"2026-10-13T03:21:45.123Z"}}"#, statusCode: 200),
        ])
        let client = try makeClient(transport)

        #expect(try await client.marker(for: .notifications) == "34975862")
        try await client.saveMarker(for: .notifications, lastReadID: "34975864")

        let requests = await transport.requests
        #expect(requests.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } == [URLQueryItem(name: "timeline[]", value: "notifications")])
        #expect(requests.last?.httpBody.map { String(decoding: $0, as: UTF8.self) } == "notifications%5Blast_read_id%5D=34975864")
    }

    private static let interactedStatus = #"{"id":"113000000000000001","created_at":"2026-10-13T03:21:45.123Z","spoiler_text":"","url":null,"content":"<p>Hello</p>","visibility":"unlisted","in_reply_to_id":null,"favourited":true,"reblogged":false,"favourites_count":2,"reblogs_count":1,"replies_count":0,"account":{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@alice","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]},"mentions":[],"tags":[],"emojis":[],"media_attachments":[],"sensitive":false}"#

    @Test func favouritePostsAndDecodesInteractionState() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])

        let status = try await makeClient(transport).favourite("113000000000000001")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v1/statuses/113000000000000001/favourite")
        #expect(status.favourited)
        #expect(status.favouritesCount == 2)
        #expect(status.reblogsCount == 1)
        #expect(status.visibility == .unlisted)
    }

    /// ブーストのAPIはブーストそのものを返すため、中の元の投稿を返す。
    @Test func reblogReturnsOriginalStatus() async throws {
        let boost = #"{"id":"113000000000000099","created_at":"2026-10-13T03:22:00.000Z","spoiler_text":"","url":null,"content":"","account":{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@alice","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]},"mentions":[],"tags":[],"emojis":[],"media_attachments":[],"sensitive":false,"reblog":"# + Self.interactedStatus + "}"
        let transport = StubTransport([.json(boost, statusCode: 200)])

        let status = try await makeClient(transport).reblog("113000000000000001")

        #expect(await transport.requests.first?.url?.path() == "/api/v1/statuses/113000000000000001/reblog")
        #expect(status.id == "113000000000000001")
    }

    @Test func postStatusSendsFormWithIdempotencyKey() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])
        let draft = StatusDraft(text: "@bob こんにちは + テスト", spoilerText: "注意", visibility: .private, inReplyToID: "113000000000000000", idempotencyKey: "key-1")

        _ = try await makeClient(transport).postStatus(draft)

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path() == "/api/v1/statuses")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "key-1")
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(components.queryItems == [
            URLQueryItem(name: "status", value: "@bob こんにちは + テスト"),
            URLQueryItem(name: "visibility", value: "private"),
            URLQueryItem(name: "spoiler_text", value: "注意"),
            URLQueryItem(name: "in_reply_to_id", value: "113000000000000000"),
        ])
    }

    @Test func defaultVisibilityReadsPreferences() async throws {
        let transport = StubTransport([.json(#"{"posting:default:visibility":"unlisted","posting:default:sensitive":false,"posting:default:language":null}"#, statusCode: 200)])

        #expect(try await makeClient(transport).defaultVisibility() == .unlisted)
        #expect(await transport.requests.first?.url?.path() == "/api/v1/preferences")
    }

    @Test func instanceConfigurationReadsStatusLimits() async throws {
        let transport = StubTransport([try .fixture("instance_v2")])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 500)
        #expect(configuration.charactersReservedPerURL == 23)
        #expect(configuration.streamingURL.absoluteString == "wss://streaming.example.social")
    }

    @Test func instanceConfigurationFallsBackWithoutStatusLimits() async throws {
        let transport = StubTransport([.json(#"{"configuration":{"urls":{"streaming":"wss://example.social"}}}"#, statusCode: 200)])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 500)
    }

    @Test func homeMarkerReadsLastReadID() async throws {
        let transport = StubTransport([.json(#"{"home":{"last_read_id":"113000000000000002","version":3,"updated_at":"2026-10-13T03:21:45.123Z"}}"#, statusCode: 200)])

        #expect(try await makeClient(transport).marker(for: .home) == "113000000000000002")
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/markers")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "timeline[]", value: "home")])
    }

    @Test func homeMarkerIsNilWhenNeverSaved() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200)])

        #expect(try await makeClient(transport).marker(for: .home) == nil)
    }

    @Test func saveHomeMarkerPostsForm() async throws {
        let transport = StubTransport([.json(#"{"home":{"last_read_id":"113000000000000003","version":4,"updated_at":"2026-10-13T03:21:45.123Z"}}"#, statusCode: 200)])

        try await makeClient(transport).saveMarker(for: .home, lastReadID: "113000000000000003")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v1/markers")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == "home%5Blast_read_id%5D=113000000000000003")
    }

    @Test func conflictingMarkerSaveIsReported() async throws {
        let transport = StubTransport([.json(#"{"error":"Conflict during update, please try again"}"#, statusCode: 409)])

        let error = await #expect(throws: MastodonAPIError.self) {
            try await makeClient(transport).saveMarker(for: .home, lastReadID: "1")
        }
        #expect(error?.statusCode == 409)
    }

    @Test func accountStatusesSendsFilterAndPage() async throws {
        let transport = StubTransport([try .fixture("home_timeline")])

        let statuses = try await makeClient(transport).accountStatuses(
            "2",
            filter: AccountStatusFilter(excludesReplies: true, excludesReblogs: false, onlyMedia: true),
            query: TimelineQuery(maxID: "100", limit: 20)
        )

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/accounts/2/statuses")
        let query = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        // 外す条件は送らない。
        #expect(query == [
            URLQueryItem(name: "exclude_replies", value: "true"),
            URLQueryItem(name: "only_media", value: "true"),
            URLQueryItem(name: "max_id", value: "100"),
            URLQueryItem(name: "limit", value: "20"),
        ])
        #expect(!statuses.isEmpty)
    }

    @Test func relationshipPicksRequestedAccount() async throws {
        let transport = StubTransport([try .fixture("relationships")])

        let relationship = try await makeClient(transport).relationship(with: "2")

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/accounts/relationships")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "id[]", value: "2")])
        #expect(relationship == Relationship(id: "2", followedBy: true, requested: true))
    }

    @Test func followAndUnfollowPostToAccount() async throws {
        let relationship = #"{"id":"2","following":true,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":false}"#
        let transport = StubTransport([.json(relationship, statusCode: 200), .json(relationship, statusCode: 200)])
        let client = try makeClient(transport)

        #expect(try await client.follow("2").following)
        _ = try await client.unfollow("2")

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/accounts/2/follow", "/api/v1/accounts/2/unfollow"])
    }
}
