import Foundation
import Testing
@testable import SciaCore

struct HashtagMuteTests {
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

    private func filter(_ id: String, action: FilterResult.Action = .hide, expiresAt: Date? = nil, keywords: [String]) -> ServerFilter {
        ServerFilter(
            id: id,
            title: "f\(id)",
            context: [.home],
            filterAction: action,
            expiresAt: expiresAt,
            keywords: keywords.enumerated().map { ServerFilter.Keyword(id: "\(id)-\($0.offset)", keyword: $0.element, wholeWord: true) }
        )
    }

    /// 隠すフィルターの`#名前`のキーワードを、サーバーのフィルターと同じく、大文字と小文字だけをそろえて探す。
    /// 警告だけのフィルター、期限の切れたフィルター、`#`のない同じ語、全角やアクセント記号の違う表記は数えない。サーバーもそれでは隠さないため。
    @Test func findsHidingFilterWithTheTagKeyword() {
        let now = Date(timeIntervalSince1970: 1_000)
        let filters = [
            filter("1", action: .warn, keywords: ["#cat"]),
            filter("2", expiresAt: now.addingTimeInterval(-1), keywords: ["#cat"]),
            filter("3", keywords: ["cat"]),
            filter("4", keywords: ["dog", "#CAT"]),
            filter("6", keywords: ["#ｃａｔ", "#cät"]),
        ]

        #expect(HashtagMute.find("Cat", in: filters, now: now) == HashtagMute(matches: [.init(filterID: "4", keywordIDs: ["4-1"], removesFilter: false)]))
        #expect(HashtagMute.find("cat", in: [filter("5", expiresAt: now.addingTimeInterval(60), keywords: ["#cat"])], now: now) == HashtagMute(matches: [.init(filterID: "5", keywordIDs: ["5-0"], removesFilter: true)]))
        #expect(HashtagMute.find("bird", in: filters, now: now) == nil)
    }

    /// 同じタグを隠す条件がいくつもあれば、すべて解除の対象にする。1つでも残すと、解除しても隠れたままになるため。
    /// 表記の違う同じタグのキーワードだけを持つフィルターは丸ごと消し、1件ずつ指定して隠す投稿もあるフィルターは、キーワードだけを消す。
    @Test func findsEveryConditionHidingTheTag() {
        let now = Date(timeIntervalSince1970: 1_000)
        let withStatus = ServerFilter(
            id: "3", title: "f3", context: [.home], filterAction: .hide,
            keywords: [ServerFilter.Keyword(id: "3-0", keyword: "#cat", wholeWord: true)],
            statuses: [ServerFilter.FilteredStatus(id: "30", statusId: "113000000000000001")]
        )
        let filters = [filter("1", keywords: ["#cat", "#Cat"]), filter("2", keywords: ["#cat", "dog"]), withStatus]

        #expect(HashtagMute.find("cat", in: filters, now: now) == HashtagMute(matches: [
            .init(filterID: "1", keywordIDs: ["1-0", "1-1"], removesFilter: true),
            .init(filterID: "2", keywordIDs: ["2-0"], removesFilter: false),
            .init(filterID: "3", keywordIDs: ["3-0"], removesFilter: false),
        ]))
    }

    /// ミュートは、`#名前`を単語として一致させ、どこでも隠すフィルターを、名前を`#名前`にして作る。期間を選べば期限を付ける。
    @Test func muteCreatesHidingFilterForTheTag() async throws {
        let created = ##"{"id":"7","title":"#cat","context":["home"],"filter_action":"hide","expires_at":null,"keywords":[{"id":"70","keyword":"#cat","whole_word":true}],"statuses":[]}"##
        let transport = StubTransport([.json(created, statusCode: 200)])

        try await HashtagMute.mute("cat", duration: .seconds(3_600), client: makeClient(transport))

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v2/filters")
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(components.queryItems == [
            URLQueryItem(name: "title", value: "#cat"),
            URLQueryItem(name: "filter_action", value: "hide"),
            URLQueryItem(name: "context[]", value: "home"),
            URLQueryItem(name: "context[]", value: "notifications"),
            URLQueryItem(name: "context[]", value: "public"),
            URLQueryItem(name: "context[]", value: "thread"),
            URLQueryItem(name: "context[]", value: "account"),
            URLQueryItem(name: "expires_in", value: "3600"),
            URLQueryItem(name: "keywords_attributes[][keyword]", value: "#cat"),
            URLQueryItem(name: "keywords_attributes[][whole_word]", value: "true"),
        ])
    }

    /// 解除は、このタグのキーワードだけのフィルターならフィルターごと消し、ほかの条件もあればこのタグのキーワードだけ消す。
    @Test func unmuteDeletesFilterOrOnlyTheKeywords() async throws {
        let transport = StubTransport(Array(repeating: .json("{}", statusCode: 200), count: 3))
        let client = try makeClient(transport)

        try await HashtagMute(matches: [
            .init(filterID: "7", keywordIDs: ["70", "71"], removesFilter: true),
            .init(filterID: "8", keywordIDs: ["80", "81"], removesFilter: false),
        ]).unmute(client: client)

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["DELETE", "DELETE", "DELETE"])
        #expect(requests.map { $0.url?.path() } == ["/api/v2/filters/7", "/api/v2/filters/keywords/80", "/api/v2/filters/keywords/81"])
    }

    @Test func filtersDecodeKeywords() async throws {
        let list = ##"[{"id":"7","title":"#cat","context":["home","public"],"filter_action":"hide","expires_at":"2026-10-25T00:00:00.000Z","keywords":[{"id":"70","keyword":"#cat","whole_word":true}],"statuses":[{"id":"71","status_id":"113000000000000001"}]}]"##
        let transport = StubTransport([.json(list, statusCode: 200)])

        let filters = try await makeClient(transport).filters()

        #expect(filters.first?.keywords == [ServerFilter.Keyword(id: "70", keyword: "#cat", wholeWord: true)])
        #expect(filters.first?.statuses == [ServerFilter.FilteredStatus(id: "71", statusId: "113000000000000001")])
        #expect(filters.first?.context == [.home, .public])
        #expect(filters.first?.expiresAt != nil)
        #expect(await transport.requests.first?.url?.path() == "/api/v2/filters")
    }
}
