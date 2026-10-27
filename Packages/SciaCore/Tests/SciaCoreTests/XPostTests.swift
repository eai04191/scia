import Foundation
import SciaTesting
import Testing
@testable import SciaCore

/// Xの投稿へのリンクを見分け、fxtwitterの応答から、作者、本文、添付ファイルを読めることを確かめる。
struct XPostTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test(arguments: [
        "https://x.com/IIDX_OFFICIAL/status/2110205221557453003",
        "https://twitter.com/IIDX_OFFICIAL/status/2110205221557453003?s=46",
        "https://mobile.twitter.com/IIDX_OFFICIAL/status/2110205221557453003/photo/1",
        "https://www.x.com/IIDX_OFFICIAL/status/2110205221557453003",
        "https://fxtwitter.com/IIDX_OFFICIAL/status/2110205221557453003",
        "https://x.com/i/web/status/2110205221557453003",
    ])
    func readsPostID(from link: String) throws {
        #expect(XPostLink.postID(in: try url(link)) == "2110205221557453003")
    }

    @Test(arguments: [
        "https://x.com/IIDX_OFFICIAL",
        "https://x.com/IIDX_OFFICIAL/status/",
        "https://x.com/IIDX_OFFICIAL/status/abc",
        "https://example.com/IIDX_OFFICIAL/status/2110205221557453003",
        "ftp://x.com/IIDX_OFFICIAL/status/2110205221557453003",
    ])
    func ignoresOtherLinks(_ link: String) throws {
        #expect(XPostLink.postID(in: try url(link)) == nil)
    }

    /// サーバーがまだカードを付けていない投稿でも、本文のリンクから読む。
    @Test func readsPostIDOfStatusWithoutCard() throws {
        let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: try url("https://example.social/a.png"))
        let status = Status(
            id: "10",
            createdAt: Date(timeIntervalSince1970: 0),
            account: account,
            content: #"<p><a href="https://x.com/IIDX_OFFICIAL/status/2110205221557453003?s=46">x.com/IIDX_OFFICIAL/status/2110205221557453003</a></p>"#,
            spoilerText: "",
            url: nil
        )

        #expect(XPostLink.postID(of: status) == "2110205221557453003")
    }

    @Test func decodesPhoto() async throws {
        let transport = StubTransport([try .fixture("fxtwitter_photo")])
        let post = try await XPostClient(client: HTTPClient(transport: transport, retry: RetryPolicy(maxRetries: 0, initialDelay: .zero), clock: TestClock())).post(id: "2110205221557453003")

        #expect(post.authorName == "【公式】beatmania IIDX")
        #expect(post.authorScreenName == "IIDX_OFFICIAL")
        #expect(post.text.plainText.hasPrefix("【WR】\n今週のWEEKLY RANKING"))
        #expect(post.createdAt != nil)
        let photo = try #require(post.media.first)
        #expect(post.media.count == 1)
        #expect(photo.type == .image)
        #expect(photo.url == (try url("https://pbs.twimg.com/media/HUjzxWxaQAA23C9.jpg?name=orig")))
        #expect(photo.previewUrl == (try url("https://pbs.twimg.com/media/HUjzxWxaQAA23C9.jpg?name=small")))
        #expect(photo.aspectRatio == 640.0 / 360.0)
        #expect(photo.id.hasPrefix("x:"))
        let request = try #require(await transport.requests.first)
        #expect(request.url == (try url("https://api.fxtwitter.com/status/2110205221557453003")))
    }

    /// 本文のリンクを、文字と行き先の組で順に返す。
    private func links(of text: RichText) -> [(String, RichText.LinkDestination)] {
        text.blocks.flatMap(\.inlines).compactMap { inline in
            if case .link(let text, let destination, _) = inline { (text, destination) } else { nil }
        }
    }

    /// URLは展開した先へのリンクにして短い形を見せ、ハッシュタグはXのページへのリンクにする。
    /// 位置はUnicodeのスカラー値で数えるため、前にある絵文字（UTF-16で2つ）の分だけずれない。末尾の添付ファイルのt.coは見せない。
    @Test func linksFacets() async throws {
        let transport = StubTransport([try .fixture("fxtwitter_facets")])
        let post = try await XPostClient(client: HTTPClient(transport: transport, retry: RetryPolicy(maxRetries: 0, initialDelay: .zero), clock: TestClock())).post(id: "1899811117221761267")

        #expect(post.text.plainText == "🚀 Status pages now support 11 languages! 🌍\n\nLearn more in our latest announcement 👉 uptimerobot.com/blog/update-st… \n\n#UptimeRobot #StatusPages #uptimemonitoring")
        let links = links(of: post.text)
        #expect(links.map(\.0) == ["uptimerobot.com/blog/update-st…", "#UptimeRobot", "#StatusPages", "#uptimemonitoring"])
        #expect(links.map(\.1) == [
            .url(try url("https://uptimerobot.com/blog/update-status-pages-now-support-11-languages/")),
            .url(try url("https://x.com/hashtag/UptimeRobot")),
            .url(try url("https://x.com/hashtag/StatusPages")),
            .url(try url("https://x.com/hashtag/uptimemonitoring")),
        ])
    }

    /// Xの本文は`<`などを文字参照のまま返し、位置も文字参照のまま数える。切り分けてから文字に戻す。
    @Test func decodesEntitiesAfterSlicing() async throws {
        let transport = StubTransport([try .fixture("fxtwitter_escaped")])
        let post = try await XPostClient(client: HTTPClient(transport: transport, retry: RetryPolicy(maxRetries: 0, initialDelay: .zero), clock: TestClock())).post(id: "1683920951807971329")

        #expect(post.text.plainText.contains("than the Twitter <iframe>\n"))
        #expect(post.text.plainText.hasSuffix("and more\n\nvercel.com/blog/introduci…"))
        #expect(links(of: post.text).map(\.1) == [.url(try url("https://vercel.com/blog/introducing-react-tweet"))])
    }

    /// 長い投稿は、見せる範囲をUTF-16の長さで返すため、全文を見せる。本文にない位置を指す添付ファイルのfacetは使わない。メンションはXのページへのリンクにする。
    @Test func linksNoteTweet() async throws {
        let transport = StubTransport([try .fixture("fxtwitter_note_tweet")])
        let post = try await XPostClient(client: HTTPClient(transport: transport, retry: RetryPolicy(maxRetries: 0, initialDelay: .zero), clock: TestClock())).post(id: "2111375640717033777")

        #expect(post.text.plainText.hasPrefix("🚀 DeepSeek-V4.1-Flash-1017 is here!\n"))
        #expect(post.text.plainText.hasSuffix("with the new model.\n\n1/4"))
        let links = links(of: post.text)
        #expect(links.map(\.0) == ["@DeepSeekHarness"])
        #expect(links.map(\.1) == [.url(try url("https://x.com/DeepSeekHarness"))])
    }

    /// Xの縮小版（`name=small`）は、長い辺を680pxに収める。一覧で元の画像を選べるよう、縮小版の大きさを実際の大きさにする。
    @Test func photoPreviewHasSmallSize() throws {
        let item = FxTwitterResponse.Item(
            id: "1", type: "photo", url: try url("https://pbs.twimg.com/media/a.jpg?name=orig"),
            thumbnailUrl: nil, width: 1800, height: 2000, altText: nil
        )
        let photo = try #require(MediaAttachment(item, postID: "9", index: 0))

        #expect(photo.meta?.original == MediaAttachment.Size(width: 1800, height: 2000))
        #expect(photo.meta?.small == MediaAttachment.Size(width: 612, height: 680))
    }

    @Test func decodesVideoAndGIF() async throws {
        let transport = StubTransport([try .fixture("fxtwitter_video"), try .fixture("fxtwitter_gif")])
        let client = XPostClient(client: HTTPClient(transport: transport, retry: RetryPolicy(maxRetries: 0, initialDelay: .zero), clock: TestClock()))

        let video = try #require(try await client.post(id: "2109995948407476369").media.first)
        #expect(video.type == .video)
        #expect(video.url?.pathExtension == "mp4")
        #expect(video.previewUrl?.host() == "pbs.twimg.com")

        let gif = try #require(try await client.post(id: "2111793760032215508").media.first)
        #expect(gif.type == .gifv)
        #expect(gif.url == (try url("https://video.twimg.com/tweet_video/HU6ZO8XbMAAmDz9.mp4")))
    }

    @Test func failsWhenPostIsMissing() async throws {
        let transport = StubTransport([try .fixture("fxtwitter_not_found", statusCode: 404)])

        await #expect(throws: HTTPStatusError(statusCode: 404)) {
            try await XPostClient(client: HTTPClient(transport: transport, retry: RetryPolicy(maxRetries: 0, initialDelay: .zero), clock: TestClock())).post(id: "1")
        }
    }

    private static let retryPolicy: @MainActor () -> RetrySchedule.Policy = { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }

    /// fxtwitterが混んでいるときの429や5xx、通信の失敗は、待てば読めるため、行を描き直したときに間隔をおいて読み直す。
    /// 再開の時刻が示されていれば、それより前には読み直さない。起動中ずっとサーバーのカードのままにしない。
    @MainActor @Test(arguments: [
        HTTPStatusError(statusCode: 429, retryAfter: .seconds(30)) as any Error & Sendable,
        HTTPStatusError(statusCode: 503),
        URLError(.notConnectedToInternet),
    ])
    func storeRetriesTemporaryFailureLater(error: any Error & Sendable) async throws {
        let counter = FetchCounter()
        let clock = TestClock()
        let post = XPost(id: "1", url: try url("https://x.com/a/status/1"), authorName: "A", authorScreenName: "a", text: .plain("本文", emojis: []))
        let store = XPostStore(clock: clock, retryPolicy: Self.retryPolicy) { id in
            await counter.increment(id)
            if await counter.count(id) == 1 { throw error }
            return post
        }
        let wait = HTTPFailure(error).flatMap { failure -> Duration? in
            if case .temporary(let retryAfter) = failure { max(retryAfter ?? .zero, .seconds(5)) } else { nil }
        } ?? .seconds(5)

        store.request(id: "1")
        try await waitUntil { store.hasFailed(id: "1") }
        clock.advance(by: wait - .seconds(1))
        store.request(id: "1")
        // 読み直すなら、あとから頼んだ投稿より先に読み始める。あとから頼んだ投稿を読み始めるまで待ってから、読み直していないことを確かめる。
        store.request(id: "2")
        try await waitUntil { await counter.count("2") == 1 }
        #expect(await counter.count("1") == 1, "間隔の前に読み直しました")

        clock.advance(by: .seconds(1))
        store.request(id: "1")
        try await waitUntil { store.post(id: "1") != nil }
        #expect(await counter.count("1") == 2)
    }

    /// 行に描いたときの読み込みなので、自動の通信として送り、止められている間は送らない。
    @MainActor @Test func storeFetchesAsAutomaticRequest() async throws {
        let origins = FetchOrigins()
        let post = XPost(id: "1", url: try url("https://x.com/a/status/1"), authorName: "A", authorScreenName: "a", text: .plain("本文", emojis: []))
        let store = XPostStore(retryPolicy: Self.retryPolicy) { _ in
            await origins.append(RequestPurpose.current)
            return post
        }
        store.request(id: "1")
        try await waitUntil { store.post(id: "1") != nil }
        #expect(await origins.values == [.display])
    }

    /// 同じ投稿を並べた行が続けて求めても、読むのは1回。読み終えたら知らせる。待っても読めない失敗（404など）の投稿は読み直さない。
    @MainActor @Test func storeFetchesOncePerPost() async throws {
        let counter = FetchCounter()
        let post = XPost(id: "1", url: try url("https://x.com/a/status/1"), authorName: "A", authorScreenName: "a", text: .plain("本文", emojis: []))
        let store = XPostStore(retryPolicy: Self.retryPolicy) { id in
            await counter.increment(id)
            if id == "1" { return post }
            throw HTTPStatusError(statusCode: 404)
        }
        var loaded: [String] = []
        try await confirmation { done in
            store.onLoad = { id in
                loaded.append(id)
                done()
            }
            store.request(id: "1")
            store.request(id: "1")
            store.request(id: "2")
            try await waitUntil { await counter.count("2") == 1 && store.post(id: "1") != nil }
        }
        store.request(id: "2")
        // 読み直すなら、あとから頼んだ投稿より先に読み始める。あとから頼んだ投稿を読み始めるまで待ってから、読み直していないことを確かめる。
        store.request(id: "3")
        try await waitUntil { await counter.count("3") == 1 }

        #expect(loaded == ["1"])
        #expect(store.post(id: "1") == post)
        #expect(store.post(id: "2") == nil)
        #expect(await counter.count("1") == 1)
        #expect(await counter.count("2") == 1)
    }

    /// ダミー投稿のために、読みに行かずに読み込み中にしておき、あとから投稿を届けられる。届けたら読み終えたときと同じく知らせる。
    @MainActor @Test func storeDeliversWithoutFetching() async throws {
        let counter = FetchCounter()
        let post = XPost(id: "1", url: try url("https://x.com/a/status/1"), authorName: "A", authorScreenName: "a", text: .plain("本文", emojis: []))
        let store = XPostStore(retryPolicy: Self.retryPolicy) { id in
            await counter.increment(id)
            return post
        }
        var loaded: [String] = []
        store.onLoad = { loaded.append($0) }

        store.reserve(id: "1")
        store.request(id: "1")
        // 読みに行くなら、あとから頼んだ投稿より先に読み始める。あとから頼んだ投稿を読み終えるまで待ってから、読みに行っていないことを確かめる。
        store.request(id: "2")
        try await waitUntil { store.post(id: "2") != nil }
        #expect(store.post(id: "1") == nil)

        store.deliver(post)
        #expect(store.post(id: "1") == post)
        #expect(loaded == ["2", "1"])
        #expect(await counter.count("1") == 0)
    }
}

private actor FetchCounter {
    private var counts: [String: Int] = [:]

    func increment(_ id: String) {
        counts[id, default: 0] += 1
    }

    func count(_ id: String) -> Int {
        counts[id] ?? 0
    }
}

private actor FetchOrigins {
    private(set) var values: [RequestPurpose] = []

    func append(_ purpose: RequestPurpose) {
        values.append(purpose)
    }
}
