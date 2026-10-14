import SciaCore
import Synchronization
import Testing
import UIKit
@testable import Scia

/// 添付ファイルのサムネイルの並べ方と、閲覧注意の覆いを確かめる。
@MainActor
@Suite(.serialized)
struct TimelineMediaTests {
    private func image(_ id: String, width: Int, height: Int, description: String? = nil) -> MediaAttachment {
        MediaAttachment(
            id: id,
            type: .image,
            url: URL(string: "https://files.example.social/original/\(id).png"),
            previewUrl: URL(string: "https://files.example.social/small/\(id).png"),
            description: description,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: width, height: height)),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        )
    }

    /// 読みに行ったURLを記録し、すべて失敗として扱う。
    private final class FetchLog: Sendable {
        private let urls = Mutex<[URL]>([])

        var fetched: [URL] { urls.withLock { $0 } }

        @MainActor func makeStore() -> MediaImageStore {
            MediaImageStore(files: .temporary()) { [self] url in
                urls.withLock { $0.append(url) }
                throw URLError(.notConnectedToInternet)
            }
        }
    }

    private func withMedia(_ base: Status, _ attachments: [MediaAttachment], sensitive: Bool = false, spoilerText: String = "") -> Status {
        Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: base.content,
            spoilerText: spoilerText,
            url: nil,
            mediaAttachments: attachments,
            sensitive: sensitive
        )
    }

    private func mediaGrid(in harness: TimelineHarness, of id: Status.ID) -> MediaGridView? {
        (harness.visibleCell(of: .status(id))?.contentView as? StatusContentView)?.mediaGrid
    }

    /// サムネイルの高さは添付ファイルの縦横比で決まり、画像が届く前から確定している。
    @Test func gridHeightFollowsAttachmentAspectRatio() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 3, startingAt: 1_000)
        let status = withMedia(statuses[0], [image("1", width: 400, height: 200)])
        harness.setStatuses([status] + statuses.dropFirst())

        let grid = try #require(mediaGrid(in: harness, of: status.id))

        #expect(grid.bounds.width > 0)
        #expect(abs(grid.bounds.height - grid.bounds.width / 2) < 0.5)
        // 添付ファイルのない投稿には出さない。
        #expect(mediaGrid(in: harness, of: statuses[1].id) == nil)
    }

    /// 閲覧注意の投稿と、注意書きのある投稿は覆う。覆いを外しても行の高さは変わらない。
    @Test func sensitiveMediaIsCoveredUntilRevealedWithoutChangingHeight() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let sensitive = withMedia(statuses[0], [image("1", width: 300, height: 400)], sensitive: true)
        let spoiler = withMedia(statuses[1], [image("2", width: 300, height: 400)], spoilerText: "ネタバレ")
        harness.setStatuses([sensitive, spoiler] + statuses.dropFirst(2))
        let vc = harness.viewController

        #expect(vc.mediaContent(for: sensitive)?.isCovered == true)
        #expect(vc.mediaContent(for: spoiler)?.isCovered == true)
        // 覆いを外す投稿のすぐ下の投稿。
        let below = spoiler.id
        let belowY = try #require(harness.windowMinY(of: .status(below)))
        let grid = try #require(mediaGrid(in: harness, of: sensitive.id))
        #expect(grid.content?.isCovered == true)

        vc.revealedMediaStatusIDs.insert(sensitive.id)
        vc.reconfigure([.status(sensitive.id)])

        #expect(mediaGrid(in: harness, of: sensitive.id)?.content?.isCovered == false)
        #expect(vc.mediaContent(for: spoiler)?.isCovered == true)
        #expect(harness.windowMinY(of: .status(below)) == belowY)
    }

    /// 新着を上に挿入しても、サムネイルのある投稿を読んでいる位置が動かない。
    @Test func insertingAboveMediaKeepsAnchor() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000).enumerated().map { offset, status in
            offset.isMultiple(of: 3) ? withMedia(status, (0..<(offset % 5 + 1)).map { image("\(offset)-\($0)", width: 300 + $0 * 100, height: 400) }) : status
        }
        harness.setStatuses(statuses)
        let anchor = statuses[30].id
        try harness.scroll(to: .status(anchor), at: .centeredVertically)
        let before = try #require(harness.windowMinY(of: .status(anchor)))

        let arrivals = StatusFactory.make(count: 5, startingAt: 1_005).map { withMedia($0, [image("new-\($0.id)", width: 200, height: 800)]) }
        harness.setStatuses(arrivals + statuses)

        let after = try #require(harness.windowMinY(of: .status(anchor)))
        #expect(abs(after - before) < 0.01, "基準の投稿が\(after - before)pt動きました")
    }

    /// 自分の投稿へのお気に入りの通知には並べず、メンションには並べる。
    @Test func onlyConversationalNotificationsShowMedia() throws {
        let vc = TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline)
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let status = withMedia(base, [image("1", width: 100, height: 100)])
        let actor = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: base.account.avatar)

        for (kind, shows) in [(MastodonNotification.Kind.mention, true), (.favourite, false), (.reblog, false)] {
            let notification = MastodonNotification(id: "1", type: kind, createdAt: .now, account: actor, status: status)
            let configuration = vc.statusContentConfiguration(list: .cell(), notification: notification)
            #expect((configuration.media != nil) == shows, "\(kind)")
        }
    }

    /// 閲覧注意で覆っている間は画像を読みに行かず、覆いを外したら読む。覆いを外さない投稿で通信しないため。
    @Test func coveredMediaIsNotFetchedUntilRevealed() async throws {
        let log = FetchLog()
        let harness = try TimelineHarness(mediaImages: log.makeStore())
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 3, startingAt: 1_000)
        let attachment = image("1", width: 400, height: 300)
        let sensitive = withMedia(statuses[0], [attachment], sensitive: true)
        harness.setStatuses([sensitive] + statuses.dropFirst())
        _ = harness.visibleCell(of: .status(sensitive.id))
        try await Task.sleep(for: .milliseconds(200))

        #expect(log.fetched.isEmpty)

        harness.viewController.revealedMediaStatusIDs.insert(sensitive.id)
        harness.viewController.reconfigure([.status(sensitive.id)])
        _ = harness.visibleCell(of: .status(sensitive.id))
        let deadline = ContinuousClock.now + .seconds(2)
        while log.fetched.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        // プレビュー画像と元の画像のどちらを読むかは、枠の大きさや回線で変わる。選び方はMediaThumbnailSelectionTestsで確かめる。
        #expect(log.fetched.count == 1)
        #expect(log.fetched.allSatisfy { [attachment.previewUrl, attachment.url].contains($0) })
    }

    /// blurhashの下地は、添付ファイルの縦横比で、長い辺を32ピクセルにする。ビューアで画像の枠を決めるのに使うため。
    @Test func placeholderKeepsAspectRatio() throws {
        let store = MediaImageStore.offline
        let wide = try #require(store.placeholder(for: "LEHV6nWB2yk8pyo0adR*.7kCMdnj", aspectRatio: 2))
        let tall = try #require(store.placeholder(for: "LEHV6nWB2yk8pyo0adR*.7kCMdnj", aspectRatio: 0.5))

        #expect(wide.cgImage?.width == 32)
        #expect(wide.cgImage?.height == 16)
        #expect(tall.cgImage?.width == 16)
        #expect(tall.cgImage?.height == 32)
        #expect(store.placeholder(for: "壊れた文字列", aspectRatio: 1) == nil)
    }
}
