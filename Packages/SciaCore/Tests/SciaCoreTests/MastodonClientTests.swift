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
}
