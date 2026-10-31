import Foundation
import Testing
@testable import SciaCore

@Suite(.requestPurpose(.action))
struct MastodonListTests {
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

    private static func formItems(of request: URLRequest) throws -> [URLQueryItem] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        return components.queryItems ?? []
    }

    @Test func decodesSettings() throws {
        let json = #"[{"id":"12249","title":"Friends","replies_policy":"followed","exclusive":true},{"id":"13585","title":"test","replies_policy":"none","exclusive":false}]"#
        let lists = try MastodonDecoder.make().decode([MastodonList].self, from: Data(json.utf8))

        #expect(lists == [
            MastodonList(id: "12249", title: "Friends", repliesPolicy: .followed, exclusive: true),
            MastodonList(id: "13585", title: "test", repliesPolicy: .noReplies, exclusive: false),
        ])
    }

    /// 設定を返さない古いサーバーや、知らない値を返すサーバーでも、リストそのものは読む。
    @Test func readsListWithoutKnownSettings() throws {
        let json = #"[{"id":"1","title":"古い"},{"id":"2","title":"知らない","replies_policy":"everyone","exclusive":"yes"}]"#
        let lists = try MastodonDecoder.make().decode([MastodonList].self, from: Data(json.utf8))

        #expect(lists == [MastodonList(id: "1", title: "古い"), MastodonList(id: "2", title: "知らない")])
    }

    /// サーバーは名前を毎回求めるので、設定だけを変えるときも名前を送る。渡さなかった設定は送らない。
    @Test func updateSendsTitleAndOnlyGivenSettings() async throws {
        let response = #"{"id":"5","title":"友だち","replies_policy":"list","exclusive":true}"#
        let transport = StubTransport([.json(response, statusCode: 200), .json(response, statusCode: 200)])
        let client = try makeClient(transport)

        let updated = try await client.updateList("5", title: "友だち", exclusive: true)
        _ = try await client.updateList("5", title: "友だち", repliesPolicy: .noReplies)

        #expect(updated == MastodonList(id: "5", title: "友だち", repliesPolicy: .list, exclusive: true))
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["PUT", "PUT"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/lists/5", "/api/v1/lists/5"])
        #expect(try Self.formItems(of: requests[0]) == [URLQueryItem(name: "title", value: "友だち"), URLQueryItem(name: "exclusive", value: "true")])
        #expect(try Self.formItems(of: requests[1]) == [URLQueryItem(name: "title", value: "友だち"), URLQueryItem(name: "replies_policy", value: "none")])
    }

    @Test func addAndRemoveAccountsSendIDs() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200), .json("{}", statusCode: 200)])
        let client = try makeClient(transport)

        try await client.addAccounts(["7", "8"], toList: "5")
        try await client.removeAccounts(["7"], fromList: "5")

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/lists/5/accounts", "/api/v1/lists/5/accounts"])
        #expect(try Self.formItems(of: requests[0]) == [URLQueryItem(name: "account_ids[]", value: "7"), URLQueryItem(name: "account_ids[]", value: "8")])
        #expect(try Self.formItems(of: requests[1]) == [URLQueryItem(name: "account_ids[]", value: "7")])
    }

    /// フォローしていない人を足そうとすると、Mastodonは404で断る。断られたことを呼び出し側に伝える。
    @Test func addingUnfollowedAccountThrows() async throws {
        let transport = StubTransport([.json(#"{"error":"Record not found"}"#, statusCode: 404)])
        let client = try makeClient(transport)

        await #expect(throws: MastodonAPIError.self) {
            try await client.addAccounts(["7"], toList: "5")
        }
    }

    @Test func listsContainingAccountUseAccountPath() async throws {
        let transport = StubTransport([.json(#"[{"id":"5","title":"友だち"}]"#, statusCode: 200)])
        let client = try makeClient(transport)

        let lists = try await client.lists(containing: "7")

        #expect(lists.map(\.id) == ["5"])
        #expect(await transport.requests.map { $0.url?.path() } == ["/api/v1/accounts/7/lists"])
    }

    @Test func membersReadWithLinkHeader() async throws {
        let account = #"{"id":"7","username":"bob","acct":"bob","display_name":"Bob","avatar":"https://example.social/avatars/bob.png","avatar_static":"https://example.social/avatars/bob.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@bob","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
        let link = #"<https://example.social/api/v1/lists/5/accounts?max_id=99>; rel="next""#
        let transport = StubTransport([.json("[\(account)]", statusCode: 200, headers: ["Link": link])])
        let client = try makeClient(transport)

        let page = try await client.accounts(in: .listMembers(listID: "5"), maxID: nil, limit: 40)

        #expect(page.accounts.map(\.id) == ["7"])
        #expect(page.nextMaxID == "99")
        #expect(await transport.requests.map { $0.url?.path() } == ["/api/v1/lists/5/accounts"])
    }

    /// 足す人を探すときは、フォローしている人に絞り、相手のサーバーには問い合わせない。
    @Test func followedSearchLimitsToFollowing() async throws {
        let transport = StubTransport([.json("[]", statusCode: 200)])
        let client = try makeClient(transport)

        _ = try await client.searchFollowedAccounts("bo", limit: 20)

        let url = try #require(await transport.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path() == "/api/v1/accounts/search")
        #expect(items.contains(URLQueryItem(name: "following", value: "true")))
        #expect(items.contains(URLQueryItem(name: "resolve", value: "false")))
    }
}
