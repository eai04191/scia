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

    /// 読めない通知は、対象の投稿のURLを開けるように残す。
    @Test func notificationsKeepUnreadableNotificationsApart() async throws {
        let body = #"[{"id":"9","type":"mention","status":{"url":"https://example.social/@alice/1"}}]"#
        let transport = StubTransport([.json(body, statusCode: 200)])

        let page = try await makeClient(transport).notifications(TimelineQuery(limit: 40))

        #expect(page.notifications.isEmpty)
        #expect(page.unreadable == [UnreadableItem(id: "9", url: URL(string: "https://example.social/@alice/1"))])
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
        let transport = StubTransport([try .fixture("notifications")])

        let notifications = try await makeClient(transport).notifications(TimelineQuery(maxID: "34975870", limit: 40)).notifications

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
            URLQueryItem(name: "sensitive", value: "false"),
            URLQueryItem(name: "spoiler_text", value: "注意"),
            URLQueryItem(name: "in_reply_to_id", value: "113000000000000000"),
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

    @Test func authorizeAndRejectFollowRequestPostToFollowRequests() async throws {
        let relationship = #"{"id":"2","following":false,"followed_by":true,"requested":false,"blocking":false,"blocked_by":false,"muting":false}"#
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
