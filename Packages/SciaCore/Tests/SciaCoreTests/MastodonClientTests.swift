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

    /// 読めない通知は、対象の投稿のURLを開けるように残す。まとまりそのものが読めなくても、最も新しい通知のIDが読めれば残す。
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

    /// まとまりは、最も新しい人と対象の投稿を引いて組み立て、人数と並べる人を添える。
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

    /// 人の一覧は、種類ごとのパスで読み、続きを`Link`ヘッダーの`max_id`で読む。
    @Test func accountListsUseTheirPathsAndLinkHeader() async throws {
        let account = #"{"id":"3","username":"carol","acct":"carol@remote.example","display_name":"Carol","avatar":"https://example.social/avatars/carol.png","avatar_static":"https://example.social/avatars/carol.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://remote.example/@carol","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
        let transport = StubTransport([
            .json("[\(account)]", statusCode: 200, headers: ["Link": #"<https://example.social/api/v1/statuses/1/favourited_by?max_id=777>; rel="next", <https://example.social/api/v1/statuses/1/favourited_by?since_id=900>; rel="prev""#]),
            .json("[]", statusCode: 200),
            .json("[]", statusCode: 200),
            .json("[]", statusCode: 200),
        ])
        let client = try makeClient(transport)

        let page = try await client.accounts(in: .favouritedBy("1"), maxID: nil, limit: 40)
        let last = try await client.accounts(in: .rebloggedBy("1"), maxID: "777", limit: 40)
        _ = try await client.accounts(in: .followers(accountID: "9"), maxID: nil, limit: 40)
        _ = try await client.accounts(in: .following(accountID: "9"), maxID: nil, limit: 40)

        #expect(page.accounts.map(\.acct) == ["carol@remote.example"])
        #expect(page.nextMaxID == "777")
        #expect(last.nextMaxID == nil)
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path() } == [
            "/api/v1/statuses/1/favourited_by",
            "/api/v1/statuses/1/reblogged_by",
            "/api/v1/accounts/9/followers",
            "/api/v1/accounts/9/following",
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
            URLQueryItem(name: "sensitive", value: "false"),
            URLQueryItem(name: "spoiler_text", value: "注意"),
            URLQueryItem(name: "in_reply_to_id", value: "113000000000000000"),
        ])
    }

    @Test func postStatusSendsPoll() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])
        let poll = PollDraft(options: [" 朝 ", "", "夜"], multiple: true, hidesTotals: true, expiresIn: 3_600)

        _ = try await makeClient(transport).postStatus(StatusDraft(text: "どっち", poll: poll, idempotencyKey: "key-1"))

        let request = try #require(await transport.requests.first)
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(components.queryItems?.filter { $0.name.hasPrefix("poll") } == [
            URLQueryItem(name: "poll[options][]", value: "朝"),
            URLQueryItem(name: "poll[options][]", value: "夜"),
            URLQueryItem(name: "poll[expires_in]", value: "3600"),
            URLQueryItem(name: "poll[multiple]", value: "true"),
            URLQueryItem(name: "poll[hide_totals]", value: "true"),
        ])
    }

    @Test func postStatusSendsMediaIDsInOrder() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])
        let attachments = ["113000000000000102", "113000000000000100"].map { id in
            DraftAttachment(state: .uploaded(MediaAttachment(id: id, type: .image, url: URL(string: "https://example.social/\(id).png"), previewUrl: nil)))
        }

        _ = try await makeClient(transport).postStatus(StatusDraft(attachments: attachments, idempotencyKey: "key-1"))

        let request = try #require(await transport.requests.first)
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(components.queryItems == [
            URLQueryItem(name: "status", value: ""),
            URLQueryItem(name: "visibility", value: "public"),
            URLQueryItem(name: "sensitive", value: "false"),
            URLQueryItem(name: "media_ids[]", value: "113000000000000102"),
            URLQueryItem(name: "media_ids[]", value: "113000000000000100"),
        ])
    }

    /// 注意書きの欄を出して空のまま添付付きで送ると、注意書きなしで閲覧注意だけを付ける。
    @Test func postStatusMarksMediaSensitiveWithEmptySpoiler() async throws {
        let transport = StubTransport([.json(Self.interactedStatus, statusCode: 200)])
        let attachment = DraftAttachment(state: .uploaded(MediaAttachment(id: "113000000000000102", type: .image, url: URL(string: "https://example.social/a.png"), previewUrl: nil)))

        _ = try await makeClient(transport).postStatus(StatusDraft(hasSpoiler: true, attachments: [attachment], idempotencyKey: "key-1"))

        let request = try #require(await transport.requests.first)
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(components.queryItems == [
            URLQueryItem(name: "status", value: ""),
            URLQueryItem(name: "visibility", value: "public"),
            URLQueryItem(name: "sensitive", value: "true"),
            URLQueryItem(name: "media_ids[]", value: "113000000000000102"),
        ])
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

        await #expect(throws: MastodonAPIError(statusCode: 422, message: message, serverMessage: message)) {
            _ = try await makeClient(transport).postStatus(StatusDraft(text: "見て"))
        }
    }

    @Test func readsPreferences() async throws {
        let transport = StubTransport([.json(#"{"posting:default:visibility":"unlisted","posting:default:sensitive":true,"posting:default:language":null,"reading:expand:media":"default","reading:expand:spoilers":true}"#, statusCode: 200)])

        #expect(try await makeClient(transport).preferences() == ServerPreferences(defaultVisibility: .unlisted, defaultSensitive: true, expandsSpoilers: true))
        #expect(await transport.requests.first?.url?.path() == "/api/v1/preferences")
    }

    /// 返さない項目は、Mastodonの既定値にする。
    @Test func missingPreferencesUseMastodonDefaults() async throws {
        let transport = StubTransport([.json("{}", statusCode: 200)])

        #expect(try await makeClient(transport).preferences() == ServerPreferences(defaultVisibility: .public, defaultSensitive: false, expandsSpoilers: false))
    }

    @Test func instanceConfigurationReadsStatusLimits() async throws {
        let transport = StubTransport([try .fixture("instance_v2")])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 500)
        #expect(configuration.charactersReservedPerURL == 23)
        #expect(configuration.streamingURL.absoluteString == "wss://streaming.example.social")
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

    /// 下限が上限を超えるような読めない値なら、既定値にする。
    @Test func pollLimitsFallBackOnInvertedExpiration() {
        #expect(MastodonClient.pollLimits((maxOptions: 6, maxCharactersPerOption: nil, minExpiration: 9_000, maxExpiration: 300)).expirationRange == PollLimits.mastodonDefault.expirationRange)
        #expect(MastodonClient.pollLimits((maxOptions: 6, maxCharactersPerOption: nil, minExpiration: nil, maxExpiration: nil)).maxOptions == 6)
    }

    @Test func instanceConfigurationReadsProfileLimits() async throws {
        let json = #"""
        {"configuration":{"urls":{"streaming":"wss://example.social"},"accounts":{"max_display_name_length":40,"max_note_length":1000,"max_profile_fields":6,"profile_field_name_limit":100,"profile_field_value_limit":2000}}}
        """#
        let transport = StubTransport([.json(json, statusCode: 200)])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.profileLimits == ProfileLimits(displayName: 40, note: 1000, fields: 6, fieldName: 100, fieldValue: 2000))
    }

    /// 4.6.0より前のMastodonは上限を返さないが、決まった値で検証している。
    @Test func instanceConfigurationUsesFixedProfileLimitsBeforeMastodon46() async throws {
        let transport = StubTransport([try .fixture("instance_v2")])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.profileLimits == ProfileLimits(displayName: 30, note: 500, fields: 4, fieldName: 255, fieldValue: 255))
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
        let relationship = #"{"id":"2","following":true,"showing_reblogs":true,"notifying":false,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false}"#
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
        let relationship = #"{"id":"2","following":true,"showing_reblogs":false,"notifying":true,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false}"#
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
        let relationship = #"{"id":"2","following":false,"showing_reblogs":true,"notifying":false,"followed_by":false,"requested":false,"blocking":false,"blocked_by":false,"muting":true,"muting_notifications":true}"#
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

    /// 通報は二重に届かないよう、一時的な失敗でも送り直さない。
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

    @Test func authorizeAndRejectFollowRequestPostToFollowRequests() async throws {
        let relationship = #"{"id":"2","following":false,"showing_reblogs":true,"notifying":false,"followed_by":true,"requested":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false}"#
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

    /// 打っている途中の問い合わせは、一時的な失敗でも送り直さない。
    @Test func completionSearchDoesNotRetry() async throws {
        let transport = StubTransport([try .fixture("error_502", withExtension: "html", statusCode: 502)])

        await #expect(throws: MastodonAPIError.self) {
            try await makeClient(transport).searchAccountsForCompletion("ca", limit: 5)
        }
        #expect(await transport.requests.count == 1)
    }

    /// リンクカードの取り直しは、リクエストを間隔ごとに1回に収めるため、一時的な失敗でも送り直さない。
    @Test func multipleStatusesDoesNotRetry() async throws {
        let transport = StubTransport([try .fixture("error_502", withExtension: "html", statusCode: 502)])

        await #expect(throws: MastodonAPIError.self) {
            try await makeClient(transport).statuses(["1"])
        }
        #expect(await transport.requests.count == 1)
    }

    /// アカウントはIDを並べて1回で読む。メニューを閉じれば要らなくなるため、一時的な失敗でも送り直さない。
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

    /// 自分の投稿の数は、文書どおりの文字列でも、Mastodonが返す数でも読む。
    @Test func featuredTags() async throws {
        let transport = StubTransport([try .fixture("featured_tags")])

        let tags = try await makeClient(transport).featuredTags()

        #expect(await transport.requests.first?.url?.path() == "/api/v1/featured_tags")
        #expect(tags == [FeaturedTag(name: "nowplaying", statusesCount: 70), FeaturedTag(name: "猫写真", statusesCount: 312)])
    }

    @Test func featuredTagSuggestions() async throws {
        let transport = StubTransport([try .fixture("featured_tags_suggestions")])

        let tags = try await makeClient(transport).featuredTagSuggestions()

        #expect(await transport.requests.first?.url?.path() == "/api/v1/featured_tags/suggestions")
        #expect(tags.map(\.name) == ["猫", "mastodev"])
    }
}
