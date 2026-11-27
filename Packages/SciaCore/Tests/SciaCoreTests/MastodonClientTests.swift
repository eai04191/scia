import Foundation
import Synchronization
import Testing
@testable import SciaCore

@Suite(.requestPurpose(.action))
struct MastodonClientTests {
    private func makeClient(_ transport: StubTransport, receivedAccounts: ReceivedAccounts? = nil) throws -> MastodonClient {
        MastodonClient(
            credential: Credential(
                instance: try #require(URL(string: "https://example.social")),
                accessToken: "token",
                clientID: "client-id",
                clientSecret: "client-secret",
                accountID: "1",
                username: "alice"
            ),
            transport: transport,
            receivedAccounts: receivedAccounts
        )
    }

    /// 投稿、予約、編集の本文。キーの順を決めて書き出すので、文字列のまま比べる。
    static func jsonBody(of request: URLRequest) throws -> String {
        String(decoding: try #require(request.httpBody), as: UTF8.self)
    }

    @Test func accountDomainUsesWebFingerDomain() async throws {
        let client = try makeClient(StubTransport([try .fixture("instance_account_domain")]))
        #expect(try await client.accountDomain() == "example.com")
    }

    /// v2の`instance`がないサーバーでは、v1の`uri`を読む。
    @Test func accountDomainFallsBackToV1WhenV2IsMissing() async throws {
        let transport = StubTransport([.json("<html>Not Found</html>", statusCode: 404), .json(#"{"uri":"EXAMPLE.COM"}"#, statusCode: 200)])
        #expect(try await makeClient(transport).accountDomain() == "example.com")
        #expect(await transport.requests.map(\.url?.path) == ["/api/v2/instance", "/api/v1/instance"])
    }

    @Test(arguments: ["", "https://example.com", "example.com/path", "a@example.com", "example.com?q=a", "example com"])
    func accountDomainRejectsMalformedValues(_ domain: String) async throws {
        let body = try JSONEncoder().encode(["domain": domain])
        let client = try makeClient(StubTransport([.json(String(decoding: body, as: UTF8.self), statusCode: 200)]))
        await #expect(throws: DecodingError.self) { try await client.accountDomain() }
    }

    /// 応答の中で読んだアカウントを、ブーストした人もブーストされた投稿の投稿者も、すべて記録する。送る前にとった番号のものより新しいものとして置き換える。
    @Test func remembersAccountsReadInResponse() async throws {
        let received = ReceivedAccounts()
        let client = try makeClient(StubTransport([try .fixture("home_timeline")]), receivedAccounts: received)
        received.remember([Account(id: "2", username: "bob", acct: "bob", displayName: "Earlier", avatar: nil)], order: received.nextOrder())

        _ = try await client.homeTimeline(TimelineQuery(limit: 40))

        #expect(received.account("1")?.username == "alice")
        #expect(received.account("2")?.displayName == "Bob")
        #expect(received.account("3")?.username == "carol")
    }

    /// ハッシュタグのページは自分のサーバーの`/tags/<名前>`で、名前の`/`や`..`はパスの区切りにせず符号化する。
    @Test func tagPageURLEncodesNameAsOneComponent() throws {
        let client = try makeClient(StubTransport([]))

        #expect(client.tagPageURL("猫").absoluteString == "https://example.social/tags/%E7%8C%AB")
        #expect(client.tagPageURL("../api").absoluteString == "https://example.social/tags/..%2Fapi")
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

    /// 読めない投稿があっても、ページの他の投稿は読む。IDが読めた投稿は、読めなかったものとして場所を残す。
    @Test func homeTimelineKeepsUnreadableStatusesApart() async throws {
        let url = try #require(Bundle.module.url(forResource: "status", withExtension: "json", subdirectory: "Fixtures"))
        let readable = try String(contentsOf: url, encoding: .utf8)
        let body = "[" + [
            readable,
            #"{"id":"112999999999999999","url":"https://example.social/@alice/112999999999999999","content":42}"#,
            #"{"content":"IDのない投稿"}"#,
        ].joined(separator: ",") + "]"
        let transport = StubTransport([.json(body, statusCode: 200)])

        let page = try await makeClient(transport).homeTimeline(TimelineQuery(limit: 40))

        #expect(page.statuses.map(\.id) == ["113000000000000001"])
        #expect(page.unreadable == [
            UnreadableItem(id: "112999999999999999", url: URL(string: "https://example.social/@alice/112999999999999999")),
        ])
    }

    /// 読めない通知は、対象の投稿のURLを開けるように残す。グループそのものが読めなくても、最も新しい通知のIDが読めれば残す。
    @Test func notificationsKeepUnreadableNotificationsApart() async throws {
        let body = #"""
        {"accounts":[],"statuses":[{"id":"1","url":"https://example.social/@alice/1"}],"notification_groups":[
          {"group_key":"ungrouped-9","notifications_count":1,"type":"mention","most_recent_notification_id":9,"page_min_id":"9","page_max_id":"9","latest_page_notification_at":"2026-10-13T03:25:00.000Z","sample_account_ids":["2"],"status_id":"1"},
          {"group_key":"favourite-1-489000","most_recent_notification_id":8}
        ]}
        """#
        let transport = StubTransport([.json(body, statusCode: 200)])

        let page = try await makeClient(transport).notifications(TimelineQuery(limit: 40))

        #expect(page.notifications.isEmpty)
        #expect(page.unreadable == [
            UnreadableItem(id: "9", url: URL(string: "https://example.social/@alice/1"), pageMinID: "9"),
            UnreadableItem(id: "8", url: nil),
        ])
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
        // どのアカウントの通信が断られたかを持ち、そのアカウントでログインし直すボタンを出せるようにする。
        #expect(error?.account == RequestAccount(id: "https://example.social#1", handle: "@alice@example.social"))
    }

    /// 「別のアカウントで」使うほかのアカウントのクライアントなら、断られた通信のアカウントに`isOtherAccount`を付ける。理由にハンドルを出すため。
    @Test func otherAccountClientMarksFailures() async throws {
        let transport = StubTransport([.json(#"{"error":"The access token is invalid"}"#, statusCode: 401)])
        let client = MastodonClient(credential: Credential(instance: try #require(URL(string: "https://example.social")), accessToken: "token", clientID: "client-id", clientSecret: "client-secret", accountID: "1", username: "alice"), transport: transport, isOtherAccount: true)

        let error = await #expect(throws: MastodonAPIError.self) {
            _ = try await client.homeTimeline(TimelineQuery(limit: 40))
        }
        #expect(error?.account?.isOtherAccount == true)
    }

    /// アカウントの他の項目が読めないサーバーでも確かめられるよう、IDだけを読む。
    @Test func verifyCredentialsReadsOnlyID() async throws {
        let transport = StubTransport([.json(#"{"id":"1","avatar":""}"#, statusCode: 200)])

        try await makeClient(transport).verifyCredentials()
        #expect(await transport.requests.first?.url?.path() == "/api/v1/accounts/verify_credentials")
    }

    @Test func notificationsDecodeKnownAndUnknownTypes() async throws {
        let transport = StubTransport([try .fixture("grouped_notifications")])

        let notifications = try await makeClient(transport).notifications(TimelineQuery(maxID: "34975870", limit: 40)).notifications

        #expect(notifications.map(\.id) == ["34975864", "34975863", "34975862", "34975861"])
        #expect(notifications.map(\.type) == [.other("admin.sign_up"), .mention, .follow, .favourite])
        #expect(notifications[0].account.displayNameOrUsername == "dave")
        #expect(notifications[1].status?.mentions.map(\.acct) == ["alice"])
        #expect(notifications[2].status == nil)
        #expect(notifications[2].account.emojis.map(\.shortcode) == ["blobcat"])
        #expect(notifications[3].status?.id == "113000000000000001")
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v2/notifications")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "max_id", value: "34975870")))
        #expect(query.contains(URLQueryItem(name: "limit", value: "40")))
        #expect(query.filter { $0.name == "grouped_types[]" }.map(\.value) == ["favourite", "reblog", "follow"])
    }

    /// グループは、最も新しい人と対象の投稿を引いて組み立て、人数と並べる人を添える。
    /// `most_recent_notification_id`はMastodonが数値で返すが、並びには`page_max_id`を使う。
    @Test func groupedNotificationsCarryCountAndSampleAccounts() async throws {
        let transport = StubTransport([try .fixture("grouped_notifications")])

        let favourite = try #require(try await makeClient(transport).notifications(TimelineQuery(limit: 40)).notifications.last)

        #expect(favourite.groupKey == "favourite-113000000000000001-489000")
        #expect(favourite.notificationsCount == 5)
        #expect(favourite.isGroup)
        #expect(favourite.sampleAccounts.map(\.id) == ["2", "3", "4"])
        #expect(favourite.account.id == "2")
        #expect(favourite.pageMinID == "34975801")
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

    @Test func votePostsChoicesAndDecodesPoll() async throws {
        let transport = StubTransport([try .fixture("poll_voted")])

        let poll = try await makeClient(transport).vote("34830", choices: [0, 1])

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v1/polls/34830/votes")
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == "choices%5B%5D=0&choices%5B%5D=1")
        #expect(poll.voted)
        #expect(poll.ownVotes == [0, 1])
        #expect(poll.votersCount == 6)
        #expect(poll.emojis.map(\.shortcode) == ["blobcat"])
    }

    @Test func pollGetsItsPath() async throws {
        let transport = StubTransport([try .fixture("poll_voted")])

        let poll = try await makeClient(transport).poll("34830")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/api/v1/polls/34830")
        #expect(poll.options.map(\.votesCount) == [6, 4])
    }

    @Test func bookmarkAndUnbookmarkPostToTheirPaths() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200), .json(Self.interactedStatus, statusCode: 200)])
        let client = try makeClient(transport)

        _ = try await client.bookmark("113000000000000001")
        _ = try await client.unbookmark("113000000000000001")

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/statuses/113000000000000001/bookmark", "/api/v1/statuses/113000000000000001/unbookmark"])
    }

    @Test func muteAndUnmuteConversationPostToTheirPathsAndDecodeMuted() async throws {
        let muted = Self.interactedStatus.replacingOccurrences(of: #""favourited":true"#, with: #""favourited":true,"muted":true"#)
        let transport = StubTransport([.json(muted, statusCode: 200), .json(Self.interactedStatus, statusCode: 200)])
        let client = try makeClient(transport)

        #expect(try await client.muteConversation("113000000000000001").muted)
        #expect(try await !client.unmuteConversation("113000000000000001").muted)

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/statuses/113000000000000001/mute", "/api/v1/statuses/113000000000000001/unmute"])
    }

    @Test func pinAndUnpinPostToTheirPathsAndDecodePinned() async throws {
        let pinned = Self.interactedStatus.replacingOccurrences(of: #""favourited":true"#, with: #""favourited":true,"pinned":true"#)
        let transport = StubTransport([.json(pinned, statusCode: 200), .json(Self.interactedStatus, statusCode: 200)])
        let client = try makeClient(transport)

        #expect(try await client.pin("113000000000000001").pinned)
        // 固定できない投稿では`pinned`が返らないため、ないときは固定していないものとして読む。
        #expect(try await !client.unpin("113000000000000001").pinned)

        let requests = await transport.requests
        #expect(requests.map { $0.url?.path() } == ["/api/v1/statuses/113000000000000001/pin", "/api/v1/statuses/113000000000000001/unpin"])
    }

    @Test func dismissNotificationGroupPostsToItsPath() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200)])

        try await makeClient(transport).dismissNotificationGroup("favourite-113000000000000001-489000")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v2/notifications/favourite-113000000000000001-489000/dismiss")
    }

    /// 絵文字でリアクションした人は、Fedibirdの`emoji_reactioned_by`を読み、その絵文字の名前のものだけに絞る。
    /// 絞ったページに人がいなければ、合う人が見つかるまで続けて読み、見つかったページの`max_id`を続きにする。
    @Test func emojiReactionedByFiltersByNameAndSkipsEmptyPages() async throws {
        func account(_ id: String) -> String {
            #"{"id":"\#(id)","username":"u\#(id)","acct":"u\#(id)","display_name":"","avatar":"https://example.social/a.png","avatar_static":"https://example.social/a.png","header":"https://example.social/h.png","header_static":"https://example.social/h.png","note":"","url":"https://example.social/@u\#(id)","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
        }
        func link(_ maxID: String) -> [String: String] {
            ["Link": "<https://example.social/api/v1/statuses/1/emoji_reactioned_by?max_id=\(maxID)>; rel=\"next\""]
        }
        let transport = StubTransport([
            .json(#"[{"name":"🎉","account":\#(account("1"))}]"#, statusCode: 200, headers: link("50")),
            .json(#"[{"name":"👍","account":\#(account("2"))},{"name":"🎉","account":\#(account("3"))},{"name":"👍","account":\#(account("4"))}]"#, statusCode: 200, headers: link("40")),
            .json("[]", statusCode: 200),
        ])
        let client = try makeClient(transport)

        let first = try await client.accounts(in: .emojiReactionedBy("1", name: "👍"), maxID: nil, limit: 40)
        let last = try await client.accounts(in: .emojiReactionedBy("1", name: "👍"), maxID: first.nextMaxID, limit: 40)

        #expect(first.accounts.map(\.id) == ["2", "4"])
        #expect(first.nextMaxID == "40")
        #expect(last.accounts.isEmpty)
        #expect(last.nextMaxID == nil)
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path() } == Array(repeating: "/api/v1/statuses/1/emoji_reactioned_by", count: 3))
        #expect(requests.map { request in request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "max_id" }?.value } == [nil, "50", "40"])
    }

    /// 絞ったページが空のまま`max_id`が循環しても、同じページを読み続けずに終わる。
    /// PleromaとAkkomaでは、すべての絵文字のリアクションを読み、投稿に返った名前（ほかのサーバーのカスタム絵文字は`shortcode@host`）で選ぶ。
    @Test func pleromaReactedByReadsAccountsOfEmoji() async throws {
        func account(_ id: String) -> String {
            #"{"id":"\#(id)","username":"u\#(id)","acct":"u\#(id)","display_name":"","avatar":"https://example.social/a.png","avatar_static":"https://example.social/a.png","header":"https://example.social/h.png","header_static":"https://example.social/h.png","note":"","url":"https://example.social/@u\#(id)","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
        }
        let transport = StubTransport([.json(#"[{"name":"🎉","accounts":[\#(account("1"))]},{"name":"neofox@misskey.example","accounts":[\#(account("2"))]}]"#, statusCode: 200)])
        let client = try makeClient(transport)

        let page = try await client.accounts(in: .emojiReactionedBy("1", name: "neofox@misskey.example"), maxID: nil, limit: 40, emojiReactionStyle: .pleroma)

        #expect(page.accounts.map(\.acct) == ["u2"])
        #expect(page.nextMaxID == nil)
        #expect(await transport.requests.map(\.url?.path) == ["/api/v1/pleroma/statuses/1/reactions"])
    }

    @Test func emojiReactionedByStopsOnCyclingCursor() async throws {
        func page(next: String) -> StubTransport.Response {
            .json(#"[{"name":"🎉","account":{"id":"1","username":"u","acct":"u","display_name":"","avatar":"https://example.social/a.png","avatar_static":"https://example.social/a.png","header":"https://example.social/h.png","header_static":"https://example.social/h.png","note":"","url":"https://example.social/@u","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}}]"#, statusCode: 200, headers: ["Link": "<https://example.social/api/v1/statuses/1/emoji_reactioned_by?max_id=\(next)>; rel=\"next\""])
        }
        let transport = StubTransport([page(next: "50"), page(next: "40"), page(next: "50"), page(next: "40")])
        let client = try makeClient(transport)

        let result = try await client.accounts(in: .emojiReactionedBy("1", name: "👍"), maxID: nil, limit: 40)

        #expect(result.accounts.isEmpty)
        #expect(result.nextMaxID == nil)
        #expect(await transport.requests.count == 3)
    }

    /// 人のリストは、種類ごとのパスで読み、続きを`Link`ヘッダーの`max_id`で読む。
    @Test func accountListsUseTheirPathsAndLinkHeader() async throws {
        let account = #"{"id":"3","username":"carol","acct":"carol@remote.example","display_name":"Carol","avatar":"https://example.social/avatars/carol.png","avatar_static":"https://example.social/avatars/carol.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://remote.example/@carol","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
        let transport = StubTransport([
            .json("[\(account)]", statusCode: 200, headers: ["Link": #"<https://example.social/api/v1/statuses/1/favourited_by?max_id=777>; rel="next", <https://example.social/api/v1/statuses/1/favourited_by?since_id=900>; rel="prev""#]),
            .json("[]", statusCode: 200),
            .json("[]", statusCode: 200),
            .json("[]", statusCode: 200),
            .json("[]", statusCode: 200),
        ])
        let client = try makeClient(transport)

        let page = try await client.accounts(in: .favouritedBy("1"), maxID: nil, limit: 40)
        let last = try await client.accounts(in: .rebloggedBy("1"), maxID: "777", limit: 40)
        _ = try await client.accounts(in: .followers(accountID: "9"), maxID: nil, limit: 40)
        _ = try await client.accounts(in: .following(accountID: "9"), maxID: nil, limit: 40)
        _ = try await client.accounts(in: .endorsements(accountID: "9"), maxID: nil, limit: 40)

        #expect(page.accounts.map(\.acct) == ["carol@remote.example"])
        #expect(page.nextMaxID == "777")
        #expect(last.nextMaxID == nil)
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path() } == [
            "/api/v1/statuses/1/favourited_by",
            "/api/v1/statuses/1/reblogged_by",
            "/api/v1/accounts/9/followers",
            "/api/v1/accounts/9/following",
            "/api/v1/accounts/9/endorsements",
        ])
        #expect(requests[1].url?.query()?.contains("max_id=777") == true)
    }

    /// 公開範囲を選んだときだけ`visibility`を送る。選ばなければ、サーバーがアカウントの既定の公開範囲でブーストする。
    @Test func reblogSendsVisibilityOnlyWhenChosen() async throws {
        let boost = #"{"id":"113000000000000099","created_at":"2026-10-13T03:22:00.000Z","spoiler_text":"","url":null,"content":"","account":{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@alice","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]},"mentions":[],"tags":[],"emojis":[],"media_attachments":[],"sensitive":false,"reblog":"# + Self.interactedStatus + "}"
        let transport = StubTransport([.json(boost, statusCode: 200), .json(boost, statusCode: 200)])
        let client = try makeClient(transport)

        _ = try await client.reblog("113000000000000001", visibility: .private)
        _ = try await client.reblog("113000000000000001")

        let bodies = await transport.requests.map { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } }
        #expect(bodies == ["visibility=private", ""])
    }

    /// ブーストのAPIはブーストそのものを返すため、中の元の投稿を返す。
    @Test func reblogReturnsOriginalStatus() async throws {
        let boost = #"{"id":"113000000000000099","created_at":"2026-10-13T03:22:00.000Z","spoiler_text":"","url":null,"content":"","account":{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@alice","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]},"mentions":[],"tags":[],"emojis":[],"media_attachments":[],"sensitive":false,"reblog":"# + Self.interactedStatus + "}"
        let transport = StubTransport([.json(boost, statusCode: 200)])

        let status = try await makeClient(transport).reblog("113000000000000001")

        #expect(await transport.requests.first?.url?.path() == "/api/v1/statuses/113000000000000001/reblog")
        #expect(status.id == "113000000000000001")
    }

    @Test func postStatusSendsJSONWithIdempotencyKey() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])
        let draft = StatusDraft(text: "@bob こんにちは + テスト", spoilerText: "注意", visibility: .private, inReplyToID: "113000000000000000", idempotencyKey: "key-1")

        _ = try await makeClient(transport).postStatus(draft)

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path() == "/api/v1/statuses")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "key-1")
        #expect(try Self.jsonBody(of: request) == #"{"in_reply_to_id":"113000000000000000","sensitive":false,"spoiler_text":"注意","status":"@bob こんにちは + テスト","visibility":"private"}"#)
    }

    /// 言語を選んでいれば送り、選んでいなければ送らずにサーバーに任せる。
    @Test(arguments: [("en", #"{"language":"en","sensitive":false,"status":"hello","visibility":"public"}"#), (nil, #"{"sensitive":false,"status":"hello","visibility":"public"}"#)] as [(String?, String)])
    func postStatusSendsLanguageOnlyWhenChosen(language: String?, expected: String) async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])

        _ = try await makeClient(transport).postStatus(StatusDraft(text: "hello", idempotencyKey: "key-1", language: language))

        #expect(try Self.jsonBody(of: try #require(await transport.requests.first)) == expected)
    }

    @Test func readsPostingLanguages() async throws {
        let transport = StubTransport([.json(#"[{"code":"ja","name":"Japanese"},{"code":"zh-TW","name":"Chinese (Taiwan)"}]"#, statusCode: 200)])

        #expect(try await makeClient(transport).postingLanguages() == [PostingLanguage(code: "ja", name: "Japanese"), PostingLanguage(code: "zh-TW", name: "Chinese (Taiwan)")])
        #expect(await transport.requests.first?.url?.path() == "/api/v1/instance/languages")
    }

    /// 引用元のIDは、Mastodonの形では`quoted_status_id`で送る。
    @Test func postStatusSendsQuotedStatusID() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])

        _ = try await makeClient(transport).postStatus(StatusDraft(text: "見て", quotedStatusID: "113000000000000000", idempotencyKey: "key-1"))

        #expect(try Self.jsonBody(of: try #require(await transport.requests.first)) == #"{"quoted_status_id":"113000000000000000","sensitive":false,"status":"見て","visibility":"public"}"#)
    }

    /// Fedibirdの形では`quote_id`で送る。`quoted_status_id`では、引用のない投稿として受け付けられる。
    @Test func postStatusSendsQuoteIDToFedibird() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])

        _ = try await makeClient(transport).postStatus(StatusDraft(text: "見て", quotedStatusID: "113000000000000000", idempotencyKey: "key-1"), quotes: .fedibird)

        #expect(try Self.jsonBody(of: try #require(await transport.requests.first)) == #"{"quote_id":"113000000000000000","sensitive":false,"status":"見て","visibility":"public"}"#)
    }

    @Test func readsQuoteRulesFromInstance() async throws {
        let fedibird = StubTransport([.json(#"{"feature_quote":true,"fedibird_capabilities":["emoji_reaction"]}"#, statusCode: 200)])
        #expect(try await makeClient(fedibird).serverCapabilities() == ServerCapabilities(supportsEmojiReactions: true, hasLocalTimeline: true, quotes: .fedibird))

        let mastodon = StubTransport([.json(#"{"version":"4.5.0"}"#, statusCode: 200)])
        #expect(try await makeClient(mastodon).serverCapabilities() == .mastodon)
    }

    /// `configuration.reactions`を返すサーバーでは、`api_versions`にChuckyaの宣言があるかで形を決める。
    /// v2の`instance`がないサーバーでだけv1を読み、宣言がないものとして扱う。
    @Test func readsReactionStyleFromInstance() async throws {
        let chuckya = StubTransport([.json(#"{"configuration":{"reactions":{"max_reactions":1}},"api_versions":{"mastodon":12,"glitch":1,"chuckya":5}}"#, statusCode: 200)])
        #expect(try await makeClient(chuckya).serverCapabilities().emojiReactions == .chuckya)
        #expect(await chuckya.requests.map(\.url?.path) == ["/api/v2/instance"])

        let firefish = StubTransport([.json(#"{"configuration":{"reactions":{"max_reactions":1}},"api_versions":{"mastodon":7}}"#, statusCode: 200)])
        #expect(try await makeClient(firefish).serverCapabilities().emojiReactions == .firefish)

        let reactions = #"{"configuration":{"reactions":{"max_reactions":1}}}"#
        let withoutVersions = StubTransport([.json(reactions, statusCode: 200)])
        #expect(try await makeClient(withoutVersions).serverCapabilities().emojiReactions == .firefish)

        // SharkeyとIceshrimpには`api/v2/instance`がない。
        let withoutV2 = StubTransport([.json(#"{"error":"Unknown API endpoint."}"#, statusCode: 404), .json(reactions, statusCode: 200)])
        #expect(try await makeClient(withoutV2).serverCapabilities().emojiReactions == .firefish)
        #expect(await withoutV2.requests.map(\.url?.path) == ["/api/v2/instance", "/api/v1/instance"])

        let pleroma = StubTransport([.json(#"{"pleroma":{"metadata":{"features":["pleroma_api","pleroma_emoji_reactions"]}}}"#, statusCode: 200)])
        #expect(try await makeClient(pleroma).serverCapabilities().emojiReactions == .pleroma)
        #expect(await pleroma.requests.count == 1)

        let mastodon = StubTransport([.json(#"{"configuration":{"statuses":{}}}"#, statusCode: 200)])
        #expect(try await makeClient(mastodon).serverCapabilities().emojiReactions == nil)
        #expect(await mastodon.requests.count == 1)
    }

    /// 付け外しは、形ごとの経路と名前で送る。
    @Test func sendsEmojiReactionInServerStyle() async throws {
        let blobcat = ReactionEmoji(name: "blobcat", url: URL(string: "https://example.social/blobcat.png"))
        var sent: [String] = []
        for style in [EmojiReactionStyle.fedibird, .chuckya, .firefish, .pleroma] {
            let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200), .json(Self.interactedStatus, statusCode: 200)])
            let client = try makeClient(transport)
            _ = try await client.addEmojiReaction("1", emoji: blobcat, style: style)
            _ = try await client.removeEmojiReaction("1", emoji: blobcat, style: style)
            sent += await transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        }
        #expect(sent == [
            "PUT /api/v1/statuses/1/emoji_reactions/blobcat", "DELETE /api/v1/statuses/1/emoji_reactions/blobcat",
            "POST /api/v1/statuses/1/react/blobcat", "POST /api/v1/statuses/1/unreact/blobcat",
            "POST /api/v1/statuses/1/react/:blobcat:", "POST /api/v1/statuses/1/unreact/:blobcat:",
            "PUT /api/v1/pleroma/statuses/1/reactions/blobcat", "DELETE /api/v1/pleroma/statuses/1/reactions/blobcat",
        ])
    }

    /// サーバーの版、投稿欄の上限、機能の有無は、v2の`instance`を1回だけ読んで同じ応答を使う。
    /// 1つの項目を読めなくても、ほかの項目は同じ応答から読む。
    @Test func instanceReadersShareOneResponse() async throws {
        let transport = StubTransport([.json(#"{"version":"4.5.0","configuration":{"statuses":{"max_characters":1000}}}"#, statusCode: 200)])
        let client = try makeClient(transport)

        async let version = client.serverVersion()
        async let configuration = client.instanceConfiguration()
        async let capabilities = client.serverCapabilities()
        #expect(try await version == "4.5.0")
        #expect(try await configuration.maxCharacters == 1000)
        #expect(try await capabilities == .mastodon)
        await #expect(throws: DecodingError.self) { try await client.accountDomain() }
        #expect(await transport.requests.map(\.url?.path) == ["/api/v2/instance"])
    }

    /// 読めなかった応答はキャッシュせず、次の呼び出しで再読み込みする。
    @Test func instanceIsReadAgainAfterFailure() async throws {
        let transport = StubTransport([.json("<html>Bad Gateway</html>", statusCode: 502), .json(#"{"configuration":{}}"#, statusCode: 200)])
        let client = MastodonClient(credential: try makeClient(transport).credential, transport: transport, retry: RetryPolicy(maxRetries: 0, initialDelay: .zero))

        await #expect(throws: MastodonAPIError.self) { try await client.instanceConfiguration() }
        #expect(try await client.instanceConfiguration().maxCharacters == 500)
        #expect(try await client.serverCapabilities() == .mastodon)
        #expect(await transport.requests.count == 2)
    }

    /// 200でもJSONのオブジェクトとして読めない応答はキャッシュせず、次の呼び出しで再読み込みする。
    @Test(arguments: ["", "<html>Maintenance</html>", "[]"])
    func instanceIsReadAgainAfterUnreadableResponse(_ body: String) async throws {
        let transport = StubTransport([.json(body, statusCode: 200), .json(#"{"configuration":{"statuses":{"max_characters":1000}}}"#, statusCode: 200)])
        let client = try makeClient(transport)

        await #expect(throws: DecodingError.self) { try await client.instanceConfiguration() }
        #expect(try await client.instanceConfiguration().maxCharacters == 1000)
        #expect(await transport.requests.count == 2)
    }

    @Test func readsPersonalEmojiSetSupportFromInstance() async throws {
        let fedibird = StubTransport([.json(#"{"fedibird_capabilities":["personal_emoji_sets"]}"#, statusCode: 200)])
        #expect(try await makeClient(fedibird).serverCapabilities().supportsPersonalEmojiSets)
        #expect(!ServerCapabilities.mastodon.supportsPersonalEmojiSets)
    }

    private func form(of request: URLRequest) throws -> [URLQueryItem] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        return components.queryItems ?? []
    }

    /// 引用できる人は、選んでいれば送る。サーバーがいつも「自分のみ」にする公開範囲では`nobody`を送り、選んでいなければ送らない。
    @Test func postStatusSendsQuotePolicy() async throws {
        let transport = StubTransport(Array(repeating: .json(Self.interactedStatus, statusCode: 200), count: 3))
        let client = try makeClient(transport)

        _ = try await client.postStatus(StatusDraft(text: "a", quotePolicy: .followers))
        _ = try await client.postStatus(StatusDraft(text: "b", visibility: .private, quotePolicy: .public))
        _ = try await client.postStatus(StatusDraft(text: "c"))

        #expect(try await transport.requests.map { try Self.jsonBody(of: $0) } == [
            #"{"quote_approval_policy":"followers","sensitive":false,"status":"a","visibility":"public"}"#,
            #"{"quote_approval_policy":"nobody","sensitive":false,"status":"b","visibility":"private"}"#,
            #"{"sensitive":false,"status":"c","visibility":"public"}"#,
        ])
    }

    @Test func setQuotePolicyPutsInteractionPolicy() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])

        _ = try await makeClient(transport).setQuotePolicy(.nobody, of: "113")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path() == "/api/v1/statuses/113/interaction_policy")
        #expect(try form(of: request) == [URLQueryItem(name: "quote_approval_policy", value: "nobody")])
    }

    @Test func revokeQuotePostsToQuotedStatus() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])

        _ = try await makeClient(transport).revokeQuote(of: "113", by: "200")

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/api/v1/statuses/113/quotes/200/revoke")
    }

    /// 引用した投稿のリストは、続きの位置を`Link`ヘッダーから読む。
    @Test func quotesReadsNextPositionFromLinkHeader() async throws {
        let link = #"<https://example.social/api/v1/statuses/113/quotes?max_id=77>; rel="next""#
        let transport = StubTransport([.json("[\(Self.interactedStatus)]", statusCode: 200, headers: ["Link": link])])

        let page = try await makeClient(transport).quotes(of: "113", maxID: "99", limit: 40)

        #expect(page.statuses.map(\.id) == ["113000000000000001"])
        #expect(page.nextMaxID == "77")
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/statuses/113/quotes")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "max_id", value: "99")])
    }

    @Test(arguments: [
        (PostingDefaultChange.visibility(.unlisted), "source[privacy]", "unlisted"),
        (.sensitive(true), "source[sensitive]", "true"),
        (.language("en"), "source[language]", "en"),
        (.language(nil), "source[language]", ""),
        (.quotePolicy(.nobody), "source[quote_policy]", "nobody"),
    ])
    func updatePostingDefaultPatchesSource(change: PostingDefaultChange, name: String, value: String) async throws {
        let transport = StubTransport([.json("{}", statusCode: 200)])

        try await makeClient(transport).updatePostingDefault(change)

        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/api/v1/accounts/update_credentials")
        #expect(try form(of: request) == [URLQueryItem(name: name, value: value)])
    }

    /// 既定の引用できる人は、引用に対応していないサーバーでは返らない。
    @Test func readsDefaultQuotePolicy() async throws {
        let transport = StubTransport([.json(#"{"posting:default:quote_policy":"followers"}"#, statusCode: 200), .json("{}", statusCode: 200)])
        let client = try makeClient(transport)

        #expect(try await client.preferences().defaultQuotePolicy == .followers)
        #expect(try await client.preferences().defaultQuotePolicy == nil)
    }

    /// メディアの表示は、返らないか読めない値なら、Mastodonの既定と同じく閲覧注意だけ隠す。
    @Test(arguments: [
        (#"{"reading:expand:media":"show_all"}"#, MediaDisplay.showsAll),
        (#"{"reading:expand:media":"hide_all"}"#, .hidesAll),
        (#"{"reading:expand:media":"default"}"#, .hidesSensitive),
        (#"{"reading:expand:media":"blur"}"#, .hidesSensitive),
        ("{}", .hidesSensitive),
    ])
    func readsMediaDisplay(json: String, expected: MediaDisplay) async throws {
        let transport = StubTransport([.json(json, statusCode: 200)])

        #expect(try await makeClient(transport).preferences().mediaDisplay == expected)
    }

    @Test func postStatusSendsPoll() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])
        let poll = PollDraft(options: [" 朝 ", "", "夜"], multiple: true, hidesTotals: true, expiresIn: 3_600)

        _ = try await makeClient(transport).postStatus(StatusDraft(text: "どっち", poll: poll, idempotencyKey: "key-1"))

        let request = try #require(await transport.requests.first)
        #expect(try Self.jsonBody(of: request) == #"{"poll":{"expires_in":3600,"hide_totals":true,"multiple":true,"options":["朝","夜"]},"sensitive":false,"status":"どっち","visibility":"public"}"#)
    }

    @Test func postStatusSendsMediaIDsInOrder() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])
        let attachments = ["113000000000000102", "113000000000000100"].map { id in
            DraftAttachment(state: .uploaded(MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/\(id).png"), previewUrl: nil)))
        }

        _ = try await makeClient(transport).postStatus(StatusDraft(attachments: attachments, idempotencyKey: "key-1"))

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try Self.jsonBody(of: request) == #"{"media_ids":["113000000000000102","113000000000000100"],"sensitive":false,"status":"","visibility":"public"}"#)
    }

    /// 注意書きの欄を出して空のまま添付付きで送ると、注意書きなしで閲覧注意だけを付ける。
    @Test func postStatusMarksMediaSensitiveWithEmptySpoiler() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])
        let attachment = DraftAttachment(state: .uploaded(MediaAttachment(id: "113000000000000102", type: .image, url: URL(string: "https://example.social/a.png"), previewUrl: nil)))

        _ = try await makeClient(transport).postStatus(StatusDraft(hasSpoiler: true, attachments: [attachment], idempotencyKey: "key-1"))

        let request = try #require(await transport.requests.first)
        #expect(try Self.jsonBody(of: request) == #"{"media_ids":["113000000000000102"],"sensitive":true,"status":"","visibility":"public"}"#)
    }

    @Test func postStatusRefusesPendingAttachmentsWithoutSending() async throws {
        let transport = StubTransport([])
        let draft = StatusDraft(text: "見て", attachments: [DraftAttachment(state: .processing(serverID: "113000000000000101"))])

        await #expect(throws: StatusPostError.attachmentsNotReady) {
            _ = try await makeClient(transport).postStatus(draft)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func rejectedPostIsReported() async throws {
        let message = "Validation failed: Cannot attach files that have not finished processing. Try again in a moment!"
        let transport = StubTransport([.json(#"{"error":"\#(message)"}"#, statusCode: 422)])

        await #expect(throws: MastodonAPIError(statusCode: 422, message: message, serverMessage: message, account: RequestAccount(id: "https://example.social#1", handle: "@alice@example.social"))) {
            _ = try await makeClient(transport).postStatus(StatusDraft(text: "見て"))
        }
    }

    @Test func readsPreferences() async throws {
        let transport = StubTransport([.json(#"{"posting:default:visibility":"unlisted","posting:default:sensitive":true,"posting:default:language":null,"reading:expand:media":"default","reading:expand:spoilers":true,"reading:autoplay:gifs":true}"#, statusCode: 200)])

        #expect(try await makeClient(transport).preferences() == ServerPreferences(defaultVisibility: .unlisted, defaultSensitive: true, expandsSpoilers: true, autoplaysAnimations: true))
        #expect(await transport.requests.first?.url?.path() == "/api/v1/preferences")
    }

    @Test func readsDefaultLanguage() async throws {
        let transport = StubTransport([.json(#"{"posting:default:visibility":"public","posting:default:language":"en"}"#, statusCode: 200)])

        #expect(try await makeClient(transport).preferences().defaultLanguage == "en")
    }

    /// 既定の言語を決めていないアカウントでは、空の文字列を返すサーバーもある。
    @Test func emptyDefaultLanguageIsNone() async throws {
        let transport = StubTransport([.json(#"{"posting:default:language":""}"#, statusCode: 200)])

        #expect(try await makeClient(transport).preferences().defaultLanguage == nil)
    }

    /// 返さない項目は、Mastodonの既定値にする。
    @Test func missingPreferencesUseMastodonDefaults() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200)])

        #expect(try await makeClient(transport).preferences() == ServerPreferences(defaultVisibility: .public, defaultSensitive: false, expandsSpoilers: false, autoplaysAnimations: false))
    }

    @Test func instanceConfigurationReadsStatusLimits() async throws {
        let transport = StubTransport([try .fixture("instance_v2")])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 500)
        #expect(configuration.charactersReservedPerURL == 23)
        #expect(configuration.maxMediaAttachments == 6)
        #expect(configuration.mediaDescriptionLimit == 1500)
        #expect(configuration.supportedMediaTypes?.contains("image/heic") == true)
        #expect(configuration.mediaLimits == MediaLimits(
            imageSizeLimit: 16_777_216,
            imageMatrixLimit: 33_177_600,
            videoSizeLimit: 103_809_024,
            videoMatrixLimit: 8_294_400,
            videoFrameRateLimit: 120
        ))
        #expect(configuration.pollLimits == PollLimits(maxOptions: 5, maxCharactersPerOption: 100, expirationRange: 600...2_629_746))
    }

    @Test func instanceConfigurationFallsBackWithoutStatusLimits() async throws {
        let transport = StubTransport([.json(#"{"configuration":{"urls":{"streaming":"wss://example.social"}}}"#, statusCode: 200)])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 500)
        #expect(configuration.maxMediaAttachments == 4)
        #expect(configuration.mediaDescriptionLimit == 1500)
        #expect(configuration.supportedMediaTypes == nil)
        // 上限を返さないサーバーでは、Mastodonの既定値で補わず、分からないままにする。
        #expect(configuration.mediaLimits == MediaLimits(imageSizeLimit: nil, imageMatrixLimit: nil, videoSizeLimit: nil, videoMatrixLimit: nil, videoFrameRateLimit: nil))
        // 投票の上限は、Mastodonの既定値で補う。Mastodonは投票の上限を定数で持ち、運営者が変えられないため。
        #expect(configuration.pollLimits == .mastodonDefault)
    }

    /// ストリーミングの接続先を返さないサーバー（Hollo）でも、投稿の上限を読む。
    @Test func instanceConfigurationReadsLimitsWithoutStreamingURL() async throws {
        let transport = StubTransport([.json(#"{"configuration":{"statuses":{"max_characters":10000,"max_media_attachments":8}}}"#, statusCode: 200)])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 10000)
        #expect(configuration.maxMediaAttachments == 8)
    }

    /// 任意のファイル（`application/octet-stream`）を受け付けると返すサーバー（Pleroma）は、形式を絞らないものとして読む。
    /// 一覧のとおりに読むと、どの画像の形式も受け付けないことになり、送る前に作り直す先がなくなるため。
    @Test(arguments: [["application/octet-stream"], ["image/png", "image/heic", "application/octet-stream"]])
    func instanceConfigurationReadsOctetStreamAsAnyType(_ types: [String]) async throws {
        let body = try JSONEncoder().encode(["configuration": ["media_attachments": ["supported_mime_types": types]]])
        let transport = StubTransport([.json(String(decoding: body, as: UTF8.self), statusCode: 200)])

        #expect(try await makeClient(transport).instanceConfiguration().supportedMediaTypes == nil)
    }

    /// v2の`instance`がないサーバー（Sharkey）では、v1の`configuration`から上限を読む。
    @Test func instanceConfigurationFallsBackToV1() async throws {
        let v1 = #"""
        {"uri":"example.social","version":"3.0.0 (compatible; Sharkey 2025.4.7)","configuration":{"statuses":{"max_characters":3000,"max_media_attachments":16},"media_attachments":{"supported_mime_types":["image/png","image/jpeg"],"image_size_limit":10485760}}}
        """#
        let transport = StubTransport([.json(#"{"error":"Unknown API endpoint."}"#, statusCode: 404), .json(v1, statusCode: 200)])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 3000)
        #expect(configuration.maxMediaAttachments == 16)
        #expect(configuration.supportedMediaTypes == ["image/png", "image/jpeg"])
        #expect(configuration.mediaLimits.imageSizeLimit == 10_485_760)
        #expect(await transport.requests.map(\.url?.path) == ["/api/v2/instance", "/api/v1/instance"])
    }

    /// `configuration`を返さないPleroma系のサーバー（Akkoma）では、`instance`の一番上にあるPleromaの項目から上限を読む。
    @Test func instanceConfigurationReadsPleromaLimitsWithoutConfiguration() async throws {
        let v1 = #"""
        {"uri":"example.social","version":"2.7.2 (compatible; Akkoma 3.20.1)","max_toot_chars":5000,"description_limit":5000,"upload_limit":16000000,"poll_limits":{"max_options":20,"max_option_chars":200,"min_expiration":0,"max_expiration":31536000}}
        """#
        let transport = StubTransport([.json(#"{"error":"Not implemented"}"#, statusCode: 404), .json(v1, statusCode: 200)])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 5000)
        #expect(configuration.mediaDescriptionLimit == 5000)
        #expect(configuration.maxMediaAttachments == 4)
        #expect(configuration.supportedMediaTypes == nil)
        #expect(configuration.mediaLimits == MediaLimits(imageSizeLimit: 16_000_000, imageMatrixLimit: nil, videoSizeLimit: 16_000_000, videoMatrixLimit: nil, videoFrameRateLimit: nil))
        // 0の下限は、ほかの上限と同じく読めない値として既定値にする。
        #expect(configuration.pollLimits == PollLimits(maxOptions: 20, maxCharactersPerOption: 200, expirationRange: PollLimits.mastodonDefault.expirationRange.lowerBound...31_536_000))
    }

    /// v2の`instance`がないサーバーでも、版、ドメイン、投稿欄の上限、機能の有無、ストリーミングの接続先は、v1を1回だけ読んで同じ応答を使う。
    @Test func instanceReadersShareOneV1Response() async throws {
        let v1 = #"""
        {"uri":"example.social","version":"2.7.2 (compatible; Akkoma 3.20.1)","urls":{"streaming_api":"wss://example.social"},"max_toot_chars":5000,"pleroma":{"metadata":{"features":["pleroma_emoji_reactions"]}}}
        """#
        let transport = StubTransport([.json(#"{"error":"Not implemented"}"#, statusCode: 404), .json(v1, statusCode: 200)])
        let client = try makeClient(transport)

        async let version = client.serverVersion()
        async let domain = client.accountDomain()
        async let configuration = client.instanceConfiguration()
        async let capabilities = client.serverCapabilities()
        async let streaming = client.streamingURL()
        #expect(try await version == "2.7.2 (compatible; Akkoma 3.20.1)")
        #expect(try await domain == "example.social")
        #expect(try await configuration.maxCharacters == 5000)
        #expect(try await capabilities.emojiReactions == .pleroma)
        #expect(try await streaming.absoluteString == "wss://example.social")
        #expect(await transport.requests.map(\.url?.path) == ["/api/v2/instance", "/api/v1/instance"])
    }

    /// 下限が上限を超えるような読めない値なら、既定値にする。
    @Test func pollLimitsFallBackOnInvertedExpiration() {
        #expect(MastodonClient.pollLimits((maxOptions: 6, maxCharactersPerOption: nil, minExpiration: 9_000, maxExpiration: 300)).expirationRange == PollLimits.mastodonDefault.expirationRange)
        #expect(MastodonClient.pollLimits((maxOptions: 6, maxCharactersPerOption: nil, minExpiration: nil, maxExpiration: nil)).maxOptions == 6)
    }

    @Test func instanceConfigurationReadsProfileLimits() async throws {
        let json = #"""
        {"configuration":{"urls":{"streaming":"wss://example.social"},"accounts":{"max_display_name_length":40,"max_note_length":1000,"max_profile_fields":6,"profile_field_name_limit":100,"profile_field_value_limit":2000,"max_featured_tags":20}}}
        """#
        let transport = StubTransport([.json(json, statusCode: 200)])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.profileLimits == ProfileLimits(displayName: 40, note: 1000, fields: 6, fieldName: 100, fieldValue: 2000, featuredTags: 20))
    }

    /// 4.6.0より前のMastodonは上限を返さないが、決まった値で検証している。注目のハッシュタグの上限は4.0から返る。
    @Test func instanceConfigurationUsesFixedProfileLimitsBeforeMastodon46() async throws {
        let transport = StubTransport([try .fixture("instance_v2")])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.profileLimits == ProfileLimits(displayName: 30, note: 500, fields: 4, fieldName: 255, fieldValue: 255, featuredTags: 10))
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

    /// 補完に出す自分のタグは、ブーストを除いた自分の投稿を、このAPIの上限の40件で読む。
    @Test func recentStatusTagsReadsOwnPosts() async throws {
        let transport = StubTransport([try .fixture("home_timeline")])

        _ = try await makeClient(transport).recentStatusTags(of: "2")

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/accounts/2/statuses")
        #expect(Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []) == [
            URLQueryItem(name: "exclude_reblogs", value: "true"),
            URLQueryItem(name: "limit", value: "40"),
        ])
    }

    /// クライアントから作る補完の読み先は、そのアカウントの最近の投稿のタグも読む。ほかのアカウントで書くときに使う。
    @Test func completionSourcesReadStatusTagsOfClientAccount() async throws {
        let transport = StubTransport([try .fixture("home_timeline")])
        let client = try makeClient(transport)

        _ = try await CompletionModel.Sources(client: client).statusTags()

        #expect(await transport.requests.first?.url?.path() == "/api/v1/accounts/\(client.credential.accountID)/statuses")
    }

    @Test func relationshipPicksRequestedAccount() async throws {
        let transport = StubTransport([try .fixture("relationships")])

        let relationship = try await makeClient(transport).relationship(with: "2")

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/accounts/relationships")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "id[]", value: "2")])
        #expect(relationship == Relationship(id: "2", showingReblogs: false, followedBy: true, requested: true))
    }

    /// 何人分でも1回のリクエストで、IDを並べて送る。
    @Test func relationshipsRequestAllAccountsAtOnce() async throws {
        let transport = StubTransport([try .fixture("relationships")])

        let relationships = try await makeClient(transport).relationships(["2", "3"])

        let requests = await transport.requests
        #expect(requests.count == 1)
        let url = try #require(requests.first?.url)
        #expect(url.path() == "/api/v1/accounts/relationships")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "id[]", value: "2"),
            URLQueryItem(name: "id[]", value: "3"),
        ])
        #expect(relationships.map(\.id) == ["2"])
    }

    @Test func followAndUnfollowPostToAccount() async throws {
        let relationship = #"{"id":"2","following":true,"showing_reblogs":true,"notifying":false,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"domain_blocking":false,"endorsed":false,"note":""}"#
        let transport = StubTransport([.json(relationship, statusCode: 200), .json(relationship, statusCode: 200)])
        let client = try makeClient(transport)

        #expect(try await client.follow("2").following)
        _ = try await client.unfollow("2")

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/accounts/2/follow", "/api/v1/accounts/2/unfollow"])
    }

    /// フォローの設定は渡したものだけを送り、渡さなければサーバーの既定に任せる。
    @Test func followSendsOnlyGivenSettings() async throws {
        let relationship = #"{"id":"2","following":true,"showing_reblogs":false,"notifying":true,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"domain_blocking":false,"endorsed":false,"note":""}"#
        let transport = StubTransport([.json(relationship, statusCode: 200), .json(relationship, statusCode: 200), .json(relationship, statusCode: 200)])
        let client = try makeClient(transport)

        let changed = try await client.follow("2", reblogs: false, notify: true)
        _ = try await client.follow("2", notify: false)
        _ = try await client.follow("2")

        #expect(!changed.showingReblogs)
        #expect(changed.notifying)
        let bodies = await transport.requests.map { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        #expect(bodies == ["reblogs=false&notify=true", "notify=false", ""])
    }

    /// ミュートの時間は秒で送り、無期限なら送らない（サーバーの既定の0が無期限）。ミュート、ブロックと解除は、それぞれのパスにPOSTする。
    @Test func muteBlockAndTheirUndoPostToAccount() async throws {
        let relationship = #"{"id":"2","following":false,"showing_reblogs":true,"notifying":false,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":true,"muting_notifications":true,"domain_blocking":false,"endorsed":false,"note":""}"#
        let transport = StubTransport(Array(repeating: .json(relationship, statusCode: 200), count: 5))
        let client = try makeClient(transport)

        #expect(try await client.mute("2", duration: .seconds(3_600)).mutingNotifications)
        _ = try await client.mute("2", duration: nil)
        _ = try await client.unmute("2")
        _ = try await client.block("2")
        _ = try await client.unblock("2")

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == Array(repeating: "POST", count: 5))
        #expect(requests.map { $0.url?.path() } == ["/api/v1/accounts/2/mute", "/api/v1/accounts/2/mute", "/api/v1/accounts/2/unmute", "/api/v1/accounts/2/block", "/api/v1/accounts/2/unblock"])
        #expect(requests.map { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" } == ["duration=3600", "", "", "", ""])
    }

    /// 通報は、添える投稿とルールを配列で送る。ルールは違反のときだけ送る。
    @Test func reportPostsFormToReports() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200), .json("{}", statusCode: 200)])
        let client = try makeClient(transport)

        try await client.report(ReportRequest(accountID: "2", statusIDs: ["100"], comment: "理由", forward: true, category: .violation, ruleIDs: ["1", "3"]))
        try await client.report(ReportRequest(accountID: "2", category: .spam, ruleIDs: ["1"]))

        let requests = await transport.requests
        #expect(requests.map { $0.url?.path() } == ["/api/v1/reports", "/api/v1/reports"])
        let forms = try requests.map { request in
            var components = URLComponents()
            components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
            return components.queryItems ?? []
        }
        #expect(forms[0] == [
            URLQueryItem(name: "account_id", value: "2"),
            URLQueryItem(name: "comment", value: "理由"),
            URLQueryItem(name: "forward", value: "true"),
            URLQueryItem(name: "category", value: "violation"),
            URLQueryItem(name: "status_ids[]", value: "100"),
            URLQueryItem(name: "rule_ids[]", value: "1"),
            URLQueryItem(name: "rule_ids[]", value: "3"),
        ])
        #expect(!forms[1].contains { $0.name == "rule_ids[]" })
    }

    /// 通報は二重に届かないよう、一時的な失敗でも再送しない。
    @Test func reportIsNotRetried() async throws {
        let transport = StubTransport([.json("", statusCode: 503), .json("{}", statusCode: 200)])
        let client = try makeClient(transport)

        await #expect(throws: (any Error).self) { try await client.report(ReportRequest(accountID: "2", category: .other)) }
        #expect(await transport.requests.count == 1)
    }

    @Test func instanceRulesReadsRules() async throws {
        let transport = StubTransport([.json(#"[{"id":"1","text":"スパム禁止","hint":""},{"id":"2","text":"差別禁止"}]"#, statusCode: 200)])

        let rules = try await makeClient(transport).instanceRules()

        #expect(await transport.requests.first?.url?.path() == "/api/v1/instance/rules")
        #expect(rules == [InstanceRule(id: "1", text: "スパム禁止", hint: ""), InstanceRule(id: "2", text: "差別禁止")])
    }

    /// メモは`comment`で送り、空なら空の`comment`を送って消す。応答の関係からメモを読む。
    @Test func setNotePostsCommentAndDecodesNote() async throws {
        let written = #"{"id":"2","following":false,"showing_reblogs":true,"notifying":false,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"domain_blocking":false,"endorsed":false,"note":"前に会った & 話した"}"#
        let cleared = #"{"id":"2","following":false,"showing_reblogs":true,"notifying":false,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"domain_blocking":false,"endorsed":false,"note":""}"#
        let transport = StubTransport([.json(written, statusCode: 200), .json(cleared, statusCode: 200)])
        let client = try makeClient(transport)

        #expect(try await client.setNote("2", comment: "前に会った & 話した").note == "前に会った & 話した")
        #expect(try await client.setNote("2", comment: "").note == "")

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/accounts/2/note", "/api/v1/accounts/2/note"])
        let comments = try requests.map { request in
            var components = URLComponents()
            components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
            return components.queryItems ?? []
        }
        #expect(comments == [[URLQueryItem(name: "comment", value: "前に会った & 話した")], [URLQueryItem(name: "comment", value: "")]])
    }

    @Test func authorizeAndRejectFollowRequestPostToFollowRequests() async throws {
        let relationship = #"{"id":"2","following":false,"showing_reblogs":true,"notifying":false,"followed_by":true,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"domain_blocking":false,"endorsed":false,"note":""}"#
        let transport = StubTransport([.json(relationship, statusCode: 200), .json(relationship, statusCode: 200)])
        let client = try makeClient(transport)

        #expect(try await client.authorizeFollowRequest(from: "2").followedBy)
        _ = try await client.rejectFollowRequest(from: "3")

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/follow_requests/2/authorize", "/api/v1/follow_requests/3/reject"])
    }

    @Test func resolveAccountSearchesRemoteAccounts() async throws {
        let account = try String(contentsOf: #require(Bundle.module.url(forResource: "account", withExtension: "json", subdirectory: "Fixtures")), encoding: .utf8)
        let transport = StubTransport([.json(#"{"accounts":["# + account + #"],"statuses":[],"hashtags":[]}"#, statusCode: 200)])

        let resolved = try await makeClient(transport).resolveAccount("bob@remote.example")

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v2/search")
        #expect(Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []) == [
            URLQueryItem(name: "q", value: "bob@remote.example"),
            URLQueryItem(name: "type", value: "accounts"),
            URLQueryItem(name: "resolve", value: "true"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        #expect(resolved?.acct == "bob@remote.example")
    }

    /// Mastodonはスキームが小文字のhttpかhttpsのときだけ、検索の語をURLとして相手のサーバーに問い合わせる。大文字のスキームのリンクも、小文字にして送る。
    @Test func resolveAccountAtURLLowercasesTheScheme() async throws {
        let transport = StubTransport([.json(#"{"accounts":[],"statuses":[],"hashtags":[]}"#, statusCode: 200)])
        let url = try #require(URL(string: "HTTPS://Pixelfed.example/Bob"))

        _ = try await makeClient(transport).resolveAccount(at: url)

        let sent = try #require(await transport.requests.first?.url)
        #expect(URLComponents(url: sent, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value == "https://Pixelfed.example/Bob")
    }

    // MARK: - 補完

    @Test func searchAccountsForCompletionDoesNotResolveRemoteAccounts() async throws {
        let transport = StubTransport([try .fixture("accounts_search")])

        let accounts = try await makeClient(transport).searchAccountsForCompletion("ca", limit: 5)

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v1/accounts/search")
        #expect(Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []) == [
            URLQueryItem(name: "q", value: "ca"),
            URLQueryItem(name: "resolve", value: "false"),
            URLQueryItem(name: "limit", value: "5"),
        ])
        // 読めないアカウントがあっても、読めた分は候補にする。
        #expect(accounts.map(\.acct) == ["carol", "bob@remote.example"])
    }

    /// フォローしている人だけから探すときは、`following=true`を付ける。
    @Test func searchAccountsForCompletionCanLimitToFollowing() async throws {
        let transport = StubTransport([try .fixture("accounts_search")])

        _ = try await makeClient(transport).searchAccountsForCompletion("ca", limit: 5, following: true)

        let url = try #require(await transport.requests.first?.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "following", value: "true")) == true)
    }

    /// 打っている途中の問い合わせは、一時的な失敗でも再送しない。
    @Test func completionSearchDoesNotRetry() async throws {
        let transport = StubTransport([try .fixture("error_502", withExtension: "html", statusCode: 502)])

        await #expect(throws: MastodonAPIError.self) {
            try await makeClient(transport).searchAccountsForCompletion("ca", limit: 5)
        }
        #expect(await transport.requests.count == 1)
    }

    /// リンクカードの取り直しは、リクエストを間隔ごとに1回に収めるため、一時的な失敗でも再送しない。
    @Test func multipleStatusesDoesNotRetry() async throws {
        let transport = StubTransport([try .fixture("error_502", withExtension: "html", statusCode: 502)])

        await #expect(throws: MastodonAPIError.self) {
            try await makeClient(transport).statuses(["1"])
        }
        #expect(await transport.requests.count == 1)
    }

    /// アカウントはIDを並べて1回で読む。メニューを閉じれば要らなくなるため、一時的な失敗でも再送しない。
    @Test func multipleAccountsAreReadAtOnceWithoutRetry() async throws {
        let url = try #require(Bundle.module.url(forResource: "account", withExtension: "json", subdirectory: "Fixtures"))
        let account = try String(contentsOf: url, encoding: .utf8)
        let transport = StubTransport([.json("[\(account)]", statusCode: 200), try .fixture("error_502", withExtension: "html", statusCode: 502)])
        let client = try makeClient(transport)

        let accounts = try await client.accounts(["1", "2"])

        let requested = try #require(await transport.requests.first?.url)
        #expect(requested.path() == "/api/v1/accounts")
        #expect(URLComponents(url: requested, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "id[]", value: "1"),
            URLQueryItem(name: "id[]", value: "2"),
        ])
        #expect(accounts.count == 1)
        await #expect(throws: MastodonAPIError.self) {
            try await client.accounts(["3"])
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func searchHashtagsForCompletion() async throws {
        let transport = StubTransport([try .fixture("search_hashtags")])

        let hashtags = try await makeClient(transport).searchHashtagsForCompletion("猫", limit: 4)

        let url = try #require(await transport.requests.first?.url)
        #expect(url.path() == "/api/v2/search")
        #expect(Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []) == [
            URLQueryItem(name: "q", value: "猫"),
            URLQueryItem(name: "type", value: "hashtags"),
            URLQueryItem(name: "resolve", value: "false"),
            URLQueryItem(name: "limit", value: "4"),
        ])
        #expect(hashtags.map(\.name) == ["猫", "猫のいる暮らし", "猫写真"])
        // 数は文字列で届く。履歴のないタグは0にする。
        #expect(hashtags.map(\.recentUses) == [73, 0, 0])
    }

    @Test func customEmojis() async throws {
        let transport = StubTransport([try .fixture("custom_emojis")])

        let emojis = try await makeClient(transport).customEmojis()

        #expect(await transport.requests.first?.url?.path() == "/api/v1/custom_emojis")
        #expect(emojis.count == 7)
        #expect(emojis.first { $0.shortcode == "hidden_blob" }?.visibleInPicker == false)
        #expect(emojis.first { $0.shortcode == "blobcat" }?.category == "Blobs")
        // 選択に出すかを返さない絵文字は、出すものとして扱う。
        #expect(emojis.first { $0.shortcode == "no_picker_flag" }?.visibleInPicker == true)
    }

    /// Fedibirdの個人セットを読む。読めない絵文字と、同じカテゴリーに重なった絵文字は外す。
    @Test func personalEmojiSet() async throws {
        let transport = StubTransport([try .fixture("personal_emoji_set_stock")])

        let set = try await makeClient(transport).personalEmojiSet()

        #expect(await transport.requests.first?.url?.path() == "/api/v1/emoji_sets/personal/stock")
        #expect(set.categories.map(\.name) == ["よく選ぶ", "空", "ねこ"])
        #expect(set.categories.map { $0.entries.map(\.emoji.recentKey) } == [["👍🏽", "wide_emoji"], [], ["🐈", "hidden_blob"]])
        guard case .custom(let wide) = set.categories[0].entries[1].emoji, case .custom(let hidden) = set.categories[2].entries[1].emoji else {
            Issue.record("カスタム絵文字として読めていない")
            return
        }
        #expect(wide.url.lastPathComponent == "wide.gif")
        #expect(wide.staticUrl.lastPathComponent == "wide_static.png")
        #expect(wide.aspectRatio == 10)
        #expect(hidden.aspectRatio == nil)
        #expect(set.categories[0].entries[1].searchTerms == ["wide_emoji", "横長", "よこなが"])
        // 見出しは、絵文字の指定があればカテゴリーの中のその絵文字、なければ名前の先頭の1文字。
        #expect(set.categories.map(\.heading) == [.emoji(set.categories[0].entries[0].emoji), .text("空"), .emoji(.custom(hidden))])
    }

    /// Fedibirdが返す画像の幅と高さから、縦横比を読む。幅か高さが0のものと、大きさを返さないものは分からないものとする。
    @Test func customEmojisReadFedibirdSize() async throws {
        let transport = StubTransport([try .fixture("custom_emojis_fedibird")])

        let emojis = try await makeClient(transport).customEmojis()

        #expect(emojis.first { $0.shortcode == "wide_word" }?.aspectRatio == 1426.0 / 256.0)
        #expect(emojis.first { $0.shortcode == "zero_height" }?.aspectRatio == nil)
        #expect(emojis.first { $0.shortcode == "no_size" }?.aspectRatio == nil)
    }

    /// Fedibirdが返すエイリアスを、前後の空白を除いて読む。空の語は捨て、返さない絵文字は空にする。
    @Test func customEmojisReadFedibirdAliases() async throws {
        let transport = StubTransport([try .fixture("custom_emojis_fedibird")])

        let emojis = try await makeClient(transport).customEmojis()

        #expect(emojis.first { $0.shortcode == "wide_word" }?.aliases == ["くぅー疲れましたw", "くぅーつかれました"])
        #expect(emojis.first { $0.shortcode == "no_size" }?.aliases == [])
    }

    /// 同じショートコードの絵文字を返すサーバーでは、Mastodonのwebと同じく、後に来た1件だけを残す。
    /// 残すと、絵文字のパレットが同じ項目を2つ並べようとして落ちる。
    @Test func customEmojisKeepLastOfSameShortcode() async throws {
        let transport = StubTransport([try .fixture("custom_emojis_duplicate_shortcode")])

        let emojis = try await makeClient(transport).customEmojis()

        #expect(emojis.map(\.shortcode) == ["blobcat", "naruhodo"])
        #expect(emojis.last?.url.lastPathComponent == "naruhodo_old.png")
    }

    /// 自分の投稿の数は、文書どおりの文字列でも、Mastodonが返す数でも読む。
    @Test func featuredTags() async throws {
        let transport = StubTransport([try .fixture("featured_tags")])

        let tags = try await makeClient(transport).featuredTags()

        #expect(await transport.requests.first?.url?.path() == "/api/v1/featured_tags")
        #expect(tags.map(\.id) == ["627", "628"])
        #expect(tags.map(\.name) == ["nowplaying", "猫写真"])
        #expect(tags.map(\.statusesCount) == [70, 312])
        // 選択して開く先として読む。
        #expect(tags.first?.url?.absoluteString == "https://example.social/@alice/tagged/nowplaying")
    }

    @Test func featuredTagsOfAccount() async throws {
        let transport = StubTransport([try .fixture("featured_tags")])

        let tags = try await makeClient(transport).featuredTags(of: "9")

        #expect(await transport.requests.first?.url?.path() == "/api/v1/accounts/9/featured_tags")
        #expect(tags.map(\.name) == ["nowplaying", "猫写真"])
    }

    /// 載せるときは名前を送り、外すときは載せたことのIDを消す。載せるのは、二重に載せて断られないよう再送しない。
    @Test func featureAndUnfeatureTag() async throws {
        let tag = #"{"id":"13174","name":"猫写真","url":"https://example.social/@alice/tagged/猫写真","statuses_count":23,"last_status_at":"2026-10-22"}"#
        let transport = StubTransport([.json("", statusCode: 503), .json(tag, statusCode: 200), .json("{}", statusCode: 200)])
        let client = try makeClient(transport)

        await #expect(throws: (any Error).self) { try await client.featureTag("猫写真") }
        let featured = try await client.featureTag("猫写真")
        try await client.unfeatureTag("13174")

        #expect(featured.id == "13174")
        #expect(featured.statusesCount == 23)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "DELETE"])
        #expect(requests.map { $0.url?.path() } == ["/api/v1/featured_tags", "/api/v1/featured_tags", "/api/v1/featured_tags/13174"])
        #expect(requests[0].httpBody.map { String(decoding: $0, as: UTF8.self) } == "name=%E7%8C%AB%E5%86%99%E7%9C%9F")
    }

    /// 自分の紹介している人は、`Link`ヘッダーの`max_id`で最後まで読む。
    @Test func endorsementsReadAllPages() async throws {
        let account = #"{"id":"3","username":"carol","acct":"carol@remote.example","display_name":"Carol","avatar":"https://example.social/avatars/carol.png","avatar_static":"https://example.social/avatars/carol.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://remote.example/@carol","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
        let transport = StubTransport([
            .json("[\(account)]", statusCode: 200, headers: ["Link": #"<https://example.social/api/v1/endorsements?max_id=777>; rel="next""#]),
            .json("[\(account.replacingOccurrences(of: #""id":"3""#, with: #""id":"4""#))]", statusCode: 200),
        ])

        let accounts = try await makeClient(transport).endorsements()

        #expect(accounts.map(\.id) == ["3", "4"])
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path() } == ["/api/v1/endorsements", "/api/v1/endorsements"])
        #expect(requests[1].url?.query()?.contains("max_id=777") == true)
    }

    /// 紹介は、4.4より前のサーバーにもある`pin`と`unpin`で送り、応答の関係から紹介しているかを読む。
    @Test func endorseAndUnendorsePostToPinPaths() async throws {
        let endorsed = #"{"id":"2","following":true,"showing_reblogs":true,"notifying":false,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"domain_blocking":false,"endorsed":true,"note":""}"#
        let transport = StubTransport([.json(endorsed, statusCode: 200), .json(endorsed.replacingOccurrences(of: #""endorsed":true"#, with: #""endorsed":false"#), statusCode: 200)])
        let client = try makeClient(transport)

        let afterEndorse = try await client.endorse("2")
        let afterUnendorse = try await client.unendorse("2")

        #expect(afterEndorse.endorsed)
        #expect(!afterUnendorse.endorsed)
        #expect(await transport.requests.map { $0.url?.path() } == ["/api/v1/accounts/2/pin", "/api/v1/accounts/2/unpin"])
    }

    @Test func featuredTagSuggestions() async throws {
        let transport = StubTransport([try .fixture("featured_tags_suggestions")])

        let tags = try await makeClient(transport).featuredTagSuggestions()

        #expect(await transport.requests.first?.url?.path() == "/api/v1/featured_tags/suggestions")
        #expect(tags.map(\.name) == ["猫", "mastodev"])
    }
}
