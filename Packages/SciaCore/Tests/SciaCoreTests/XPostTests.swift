import Foundation
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
        let post = try await XPostClient(transport: transport).post(id: "2110205221557453003")

        #expect(post.authorName == "【公式】beatmania IIDX")
        #expect(post.authorScreenName == "IIDX_OFFICIAL")
        #expect(post.text.hasPrefix("【WR】\n今週のWEEKLY RANKING"))
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
        let client = XPostClient(transport: transport)

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

        await #expect(throws: XPostClient.Unavailable(statusCode: 404)) {
            try await XPostClient(transport: transport).post(id: "1")
        }
    }

    /// 同じ投稿を並べた行が続けて求めても、読むのは1回。読み終えたら知らせる。失敗した投稿は読み直さない。
    @MainActor @Test func storeFetchesOncePerPost() async throws {
        let counter = FetchCounter()
        let post = XPost(id: "1", url: try url("https://x.com/a/status/1"), authorName: "A", authorScreenName: "a", text: "本文")
        let store = XPostStore { id in
            await counter.increment(id)
            if id == "1" { return post }
            throw XPostClient.Unavailable(statusCode: 404)
        }
        var loaded: [String] = []
        await confirmation { done in
            store.onLoad = { id in
                loaded.append(id)
                done()
            }
            store.request(id: "1")
            store.request(id: "1")
            store.request(id: "2")
            while await counter.count("2") == 0 || store.post(id: "1") == nil {
                await Task.yield()
            }
        }
        store.request(id: "2")
        await Task.yield()

        #expect(loaded == ["1"])
        #expect(store.post(id: "1") == post)
        #expect(store.post(id: "2") == nil)
        #expect(await counter.count("1") == 1)
        #expect(await counter.count("2") == 1)
    }

    /// ダミー投稿のために、読みに行かずに読み込み中にしておき、あとから投稿を届けられる。届けたら読み終えたときと同じく知らせる。
    @MainActor @Test func storeDeliversWithoutFetching() async throws {
        let counter = FetchCounter()
        let post = XPost(id: "1", url: try url("https://x.com/a/status/1"), authorName: "A", authorScreenName: "a", text: "本文")
        let store = XPostStore { id in
            await counter.increment(id)
            return post
        }
        var loaded: [String] = []
        store.onLoad = { loaded.append($0) }

        store.reserve(id: "1")
        store.request(id: "1")
        await Task.yield()
        #expect(store.post(id: "1") == nil)

        store.deliver(post)
        #expect(store.post(id: "1") == post)
        #expect(loaded == ["1"])
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
