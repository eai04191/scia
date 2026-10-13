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

        let page = try await makeClient(transport).homeTimeline(maxID: nil, limit: 40)

        #expect(!page.isRegenerating)
        #expect(page.statuses.map(\.id) == ["113000000000000003", "113000000000000002"])
        let boost = try #require(page.statuses.first)
        #expect(boost.account.username == "bob")
        #expect(boost.reblog?.id == "113000000000000001")
        #expect(boost.displayed.content == "<p>ブーストされた投稿</p>")
        #expect(page.statuses[1].reblog == nil)
        #expect(page.statuses[1].displayed.id == "113000000000000002")
    }

    @Test func homeTimelineSendsPagingQueryAndToken() async throws {
        let transport = StubTransport([.json("[]", statusCode: 200)])

        _ = try await makeClient(transport).homeTimeline(maxID: "113000000000000002", limit: 40)

        let request = try #require(await transport.requests.first)
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path() == "/api/v1/timelines/home")
        #expect(query.contains(URLQueryItem(name: "max_id", value: "113000000000000002")))
        #expect(query.contains(URLQueryItem(name: "limit", value: "40")))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test func homeTimelineOmitsMaxIDForLatestPage() async throws {
        let transport = StubTransport([.json("[]", statusCode: 200)])

        _ = try await makeClient(transport).homeTimeline(maxID: nil, limit: 40)

        let url = try #require(await transport.requests.first?.url)
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        #expect(!names.contains("max_id"))
    }

    @Test func partialContentMeansRegenerating() async throws {
        let transport = StubTransport([.json("[]", statusCode: 206)])

        let page = try await makeClient(transport).homeTimeline(maxID: nil, limit: 40)

        #expect(page.isRegenerating)
        #expect(page.statuses.isEmpty)
    }

    @Test func unauthorizedIsReported() async throws {
        let transport = StubTransport([.json(#"{"error":"The access token is invalid"}"#, statusCode: 401)])

        let error = await #expect(throws: MastodonAPIError.self) {
            _ = try await makeClient(transport).homeTimeline(maxID: nil, limit: 40)
        }
        #expect(error?.isUnauthorized == true)
        #expect(error?.message == "The access token is invalid")
    }
}
