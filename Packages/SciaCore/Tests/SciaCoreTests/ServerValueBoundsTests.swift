import CoreGraphics
import Foundation
import Testing
@testable import SciaCore

/// サーバー（ほかのサーバーの利用者が書いた投稿を含む）から来る数とURLを、読むところで確かめることを確かめる。
/// Mastodonは数の範囲もリンクのスキームも確かめずに通すことがあるため、どんな値が来ても、落ちたり、ほかのアプリやファイルを開いたりしない。
struct ServerValueBoundsTests {
    // MARK: - 数

    @Test func countsAreClampedWhenRead() throws {
        let status = try decodeStatus { json in
            json["favourites_count"] = Int.max
            json["reblogs_count"] = Int.min
            json["replies_count"] = -1
            var account = try #require(json["account"] as? [String: Any])
            account["followers_count"] = Int.max
            account["following_count"] = Int.min
            account["statuses_count"] = -5
            json["account"] = account
        }

        #expect(status.favouritesCount == ServerCount.upperBound)
        #expect(status.reblogsCount == 0)
        #expect(status.repliesCount == 0)
        #expect(status.account.followersCount == ServerCount.upperBound)
        #expect(status.account.followingCount == 0)
        #expect(status.account.statusesCount == 0)
    }

    /// 上限の数の投稿をお気に入りやブーストしても、楽観的に足すところで落ちない。
    @Test func favouritingAndBoostingAtTheUpperBoundDoNotOverflow() throws {
        let status = try decodeStatus { json in
            json["favourites_count"] = Int.max
            json["reblogs_count"] = Int.max
            json["favourited"] = false
            json["reblogged"] = false
        }

        #expect(status.settingFavourited(true).favouritesCount == ServerCount.upperBound + 1)
        #expect(status.settingReblogged(true).reblogsCount == ServerCount.upperBound + 1)
    }

    @Test func groupedNotificationCountIsClampedAndCanGrow() async throws {
        let url = try #require(Bundle.module.url(forResource: "grouped_notifications", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var groups = try #require(json["notification_groups"] as? [[String: Any]])
        groups[groups.count - 1]["notifications_count"] = Int.max
        json["notification_groups"] = groups
        let transport = StubTransport([.json(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self), statusCode: 200)])

        let group = try #require(try await makeClient(transport).notifications(TimelineQuery(limit: 40)).notifications.last)
        let other = try decodeStatus { _ in }.account

        #expect(group.notificationsCount == ServerCount.upperBound)
        let arrived = MastodonNotification(id: "99999999", type: group.type, createdAt: group.createdAt, account: Account(id: "999", username: "new", acct: "new", displayName: "New", avatar: other.avatar))
        #expect(group.adding(arrived)?.notificationsCount == ServerCount.upperBound + 1)
    }

    @Test func hashtagUsesAreClampedAndTheirSumDoesNotOverflow() throws {
        let day = #"{"day":"1668556800","accounts":"9223372036854775807","uses":"9223372036854775807"}"#
        let json = #"{"name":"scia","url":"https://example.social/tags/scia","history":[\#(Array(repeating: day, count: 2_000).joined(separator: ","))]}"#

        let hashtag = try MastodonDecoder.make().decode(Hashtag.self, from: Data(json.utf8))

        #expect(hashtag.history.first?.uses == ServerCount.upperBound)
        #expect(hashtag.recentUses == ServerCount.upperBound)
    }

    /// 選択肢の票が合計より多くても、割合は0から1に収める。収めないと、百分率に直すところで落ちたり、バーが枠からはみ出したりする。
    @Test func pollFractionsStayWithinZeroAndOne() throws {
        let json = #"{"id":"1","expires_at":null,"expired":true,"multiple":false,"votes_count":1,"voters_count":null,"options":[{"title":"多い","votes_count":9223372036854775807},{"title":"負","votes_count":-9223372036854775808}],"emojis":[]}"#
        let poll = try MastodonDecoder.make().decode(Poll.self, from: Data(json.utf8))

        let display = PollDisplay(poll: poll, choices: PollChoices(), now: Date(timeIntervalSince1970: 0), allowsVoting: false)

        #expect(poll.options.map(\.votesCount) == [ServerCount.upperBound, 0])
        #expect(display.options.map(\.fraction) == [1, 0])
    }

    /// 極端に細長い添付ファイルでも、サムネイルに要る大きさを求めるところで落ちない。
    @Test func extremeAspectRatioDoesNotOverflowThumbnailSize() throws {
        for (width, height) in [(1, 100_000_000_000_000_000), (100_000_000_000_000_000, 1)] {
            let json = #"{"id":"1","type":"image","url":"https://example.social/o.png","preview_url":"https://example.social/s.png","meta":{"original":{"width":\#(width),"height":\#(height)},"small":{"width":1,"height":1}}}"#
            let attachment = try MastodonDecoder.make().decode(MediaAttachment.self, from: Data(json.utf8))

            let request = MediaThumbnailSelection.request(
                for: attachment,
                tileSize: CGSize(width: 393, height: 393),
                displayScale: 3,
                policy: MediaThumbnailPolicy(enhancement: .enhancement(onExpensiveNetwork: true), upscaleTolerance: 1)
            )

            #expect(request != nil)
        }
    }

    /// サーバーが決める投稿の上限が範囲の外なら、返さなかったものとして既定値にする。
    @Test func outOfRangeStatusLimitsFallBackToDefaults() async throws {
        let body = #"{"configuration":{"urls":{"streaming":"wss://example.social"},"statuses":{"max_characters":-9223372036854775808,"max_media_attachments":0,"characters_reserved_per_url":-1},"media_attachments":{"image_size_limit":0,"image_matrix_limit":-1,"video_size_limit":9223372036854775807,"video_matrix_limit":0,"video_frame_rate_limit":-30,"description_limit":0}}}"#
        let transport = StubTransport([.json(body, statusCode: 200)])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 500)
        #expect(configuration.maxMediaAttachments == 4)
        #expect(configuration.charactersReservedPerURL == 23)
        #expect(configuration.mediaDescriptionLimit == 1500)
        #expect(configuration.mediaLimits == MediaLimits(imageSizeLimit: nil, imageMatrixLimit: nil, videoSizeLimit: ServerCount.upperBound, videoMatrixLimit: nil, videoFrameRateLimit: nil))
    }

    /// URLの予約文字数が投稿の上限を超えるなら、返さなかったものとして既定値にする。1文字打つごとに、その長さの文字列を作るため。
    @Test func reservedCharactersPerURLAboveTheLimitFallsBack() async throws {
        let body = #"{"configuration":{"urls":{"streaming":"wss://example.social"},"statuses":{"max_characters":1000,"characters_reserved_per_url":1000000000000}}}"#
        let transport = StubTransport([.json(body, statusCode: 200)])

        let configuration = try await makeClient(transport).instanceConfiguration()

        #expect(configuration.maxCharacters == 1000)
        #expect(configuration.charactersReservedPerURL == 23)
    }

    /// 動画の容量の上限がとても大きく、動画がとても短くても、使えるビットレートを求めるところで落ちない。
    @Test func hugeVideoSizeLimitDoesNotOverflowBitRate() {
        let plan = VideoPlan.make(
            size: PixelSize(width: 3840, height: 2160),
            duration: 0.001,
            frameRate: 30,
            hasAudio: true,
            byteCount: 50_000_000,
            setting: .p1080,
            limits: MediaLimits(imageSizeLimit: nil, imageMatrixLimit: nil, videoSizeLimit: ServerCount.upperBound, videoMatrixLimit: nil, videoFrameRateLimit: nil),
            quality: VideoPlan.Quality(bitRate1080p: 8_000_000, minimumBitRate1080p: 2_000_000, sizeLimitMargin: 0.9, audioBitRate: 128_000)
        )

        #expect(plan != .tooLong)
    }

    /// 続きの位置を循環させて返すサーバーでも、同じページを読み続けない。
    @Test func followedTagsStopOnCyclingLinks() async throws {
        func page(_ id: String, next: String) -> StubTransport.Response {
            .json(#"[{"id":"\#(id)","name":"t\#(id)","url":"https://example.social/tags/t\#(id)","history":[]}]"#, statusCode: 200, headers: ["Link": #"<https://example.social/api/v1/followed_tags?max_id=\#(next)>; rel="next""#])
        }
        let transport = StubTransport([page("9", next: "8"), page("8", next: "7"), page("7", next: "8"), page("8", next: "7")])

        let tags = try await makeClient(transport).followedTags()

        #expect(tags.map(\.name) == ["t9", "t8", "t7"])
    }

    // MARK: - URL

    /// 読み込む画像やメディアのURLは、http、https、data:だけを受け付ける。data:は中身をURLの中に持ち、端末のファイルにもほかのアプリにも触れない。
    @Test func mediaURLsAcceptOnlyWebAndDataSchemes() throws {
        let status = try decodeStatus { json in
            var account = try #require(json["account"] as? [String: Any])
            account["avatar"] = "file:///private/var/mobile/secret.png"
            account["avatar_static"] = "data:image/png;base64,iVBORw0KGgo="
            account["header"] = "HTTPS://example.social/header.png"
            account["header_static"] = "/headers/original/missing.png"
            json["account"] = account
            json["media_attachments"] = [
                ["id": "9", "type": "video", "url": "file:///etc/hosts", "preview_url": "custom-app://open", "remote_url": "ftp://example.social/a.mp4", "preview_remote_url": "https://example.social/p.png", "description": NSNull(), "blurhash": NSNull()],
            ]
            json["emojis"] = [
                ["shortcode": "local", "url": "file:///etc/hosts", "static_url": "file:///etc/hosts", "visible_in_picker": true],
                ["shortcode": "blobcat", "url": "https://example.social/emoji/blobcat.png", "static_url": "https://example.social/emoji/blobcat.png", "visible_in_picker": true],
            ]
        }

        #expect(status.account.avatar == nil)
        #expect(status.account.avatarStatic?.scheme == "data")
        #expect(status.account.header?.host() == "example.social")
        #expect(status.account.headerStatic == nil)
        let attachment = try #require(status.mediaAttachments.first)
        #expect(attachment.url == nil)
        #expect(attachment.previewUrl == nil)
        #expect(attachment.remoteUrl == nil)
        #expect(attachment.previewRemoteUrl?.host() == "example.social")
        #expect(status.emojis.map(\.shortcode) == ["blobcat"])
    }

    /// 開く先のURL（投稿、アカウント、メンション、ハッシュタグ、カードのリンク先）は、httpとhttpsだけを受け付ける。
    /// ほかのスキームを外のアプリに渡すと、サーバーが選んだアプリを起動できてしまう。本文のリンクは、Mastodonがgeminiなども通す決まりなので対象外。
    @Test func destinationURLsAcceptOnlyWebSchemes() throws {
        let status = try decodeStatus { json in
            json["url"] = "javascript:alert(1)"
            var account = try #require(json["account"] as? [String: Any])
            account["url"] = "tel:0123456789"
            json["account"] = account
            json["mentions"] = [["id": "2", "username": "bob", "url": "custom-app://bob", "acct": "bob@remote.example"]]
            json["tags"] = [["name": "scia", "url": "file:///tags/scia"]]
            json["card"] = ["url": "sms:0123", "title": "t", "description": "", "type": "link", "provider_name": "", "width": 0, "height": 0]
        }

        #expect(status.url == nil)
        #expect(status.account.url == nil)
        #expect(status.mentions.first?.url == nil)
        #expect(status.tags.first?.url == nil)
        #expect(status.card == nil)
    }

    @Test func followedHashtagURLAcceptsOnlyWebSchemes() throws {
        let hashtag = try MastodonDecoder.make().decode(Hashtag.self, from: Data(#"{"name":"scia","url":"file:///tags/scia","history":[]}"#.utf8))

        #expect(hashtag.url == nil)
        #expect(hashtag.name == "scia")
    }

    // MARK: -

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

    private func decodeStatus(_ modify: (inout [String: Any]) throws -> Void) throws -> Status {
        let url = try #require(Bundle.module.url(forResource: "status", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try modify(&json)
        return try MastodonDecoder.make().decode(Status.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
