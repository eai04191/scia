import SciaCore
import SciaTesting
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
            MediaImageStore(files: .temporary()) { [self] url, _ in
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
        (harness.visibleCell(of: .status(id))?.contentView as? PostContentView)?.mediaGrid
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

        vc.revealMedia(of: sensitive)

        #expect(mediaGrid(in: harness, of: sensitive.id)?.content?.isCovered == false)
        #expect(vc.mediaContent(for: spoiler)?.isCovered == true)
        #expect(harness.windowMinY(of: .status(below)) == belowY)
    }

    /// 閲覧注意のない投稿も、メニューから隠すと覆う。覆っても行の高さは変わらず、覆いをタップすれば開く。
    @Test func hidingPlainMediaCoversItWithoutChangingHeight() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let plain = withMedia(statuses[0], [image("1", width: 300, height: 400)])
        harness.setStatuses([plain] + statuses.dropFirst())
        let vc = harness.viewController
        let below = statuses[1].id
        let belowY = try #require(harness.windowMinY(of: .status(below)))
        #expect(try #require(mediaGrid(in: harness, of: plain.id)).content?.isCovered == false)

        vc.hideMedia(of: plain)

        #expect(mediaGrid(in: harness, of: plain.id)?.content?.cover == .hidden)
        #expect(harness.windowMinY(of: .status(below)) == belowY)

        vc.revealMedia(of: plain)

        #expect(mediaGrid(in: harness, of: plain.id)?.content?.isCovered == false)
        #expect(harness.windowMinY(of: .status(below)) == belowY)
    }

    /// ほかの画面で隠した結果を受け取ると、その投稿の行を覆い直す。隠した画面は、変えたあとの状態をセッションに渡す。
    @Test func mediaCoversChangedElsewhereAreApplied() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let plain = withMedia(statuses[0], [image("1", width: 300, height: 400)])
        harness.setStatuses([plain] + statuses.dropFirst())
        let vc = harness.viewController
        var shared: MediaCovers?
        vc.onChangeMediaCovers = { covers, _ in shared = covers }
        let below = statuses[1].id
        let belowY = try #require(harness.windowMinY(of: .status(below)))

        vc.hideMedia(of: plain)
        let hidden = try #require(shared)
        #expect(hidden.cover(for: plain, filterTitles: []) == .hidden)
        vc.revealMedia(of: plain)
        #expect(mediaGrid(in: harness, of: plain.id)?.content?.isCovered == false)

        vc.applyMediaCovers(hidden, changed: plain)

        #expect(mediaGrid(in: harness, of: plain.id)?.content?.cover == .hidden)
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

    /// メンションでは投稿と同じく行の幅いっぱいに並べ、自分の投稿へのお気に入りやブーストの通知では、小さなサムネイルを1列に並べる。
    @Test func notificationMediaArrangementDependsOnKind() throws {
        let tuning = TuningStore(defaults: nil)
        let vc = TimelineViewController(refresh: {}, tuning: tuning, emojiImages: .offline, mediaImages: .offline)
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let status = withMedia(base, [image("1", width: 100, height: 100)])
        let actor = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: base.account.avatar)
        let side = tuning.value(of: TuningCatalog.notificationQuotedThumbnailSize)

        let mention = MastodonNotification(id: "1", type: .mention, createdAt: Date(timeIntervalSince1970: 0), account: actor, status: status)
        let post = try #require(vc.contentConfiguration(for: mention, base: .cell()) as? PostContentConfiguration)
        #expect(post.media?.arrangement == .grid)

        for kind in [MastodonNotification.Kind.favourite, .reblog] {
            let notification = MastodonNotification(id: "1", type: kind, createdAt: Date(timeIntervalSince1970: 0), account: actor, status: status)
            let quoted = try #require(vc.contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)
            #expect(quoted.body.media?.arrangement == .strip(side: side), "\(kind)")
        }
    }

    /// ビューアの開閉で画像を切り抜く範囲は、サムネイルの入れ物ではなく、行を並べている一覧の表示範囲にする。
    /// サムネイルを横にスクロールする入れ物に載せたとき、入れ物を一覧と取り違えて、閉じる途中に行が前に浮いて見えたことがある。
    @Test func viewerClipsToListNotThumbnailContainer() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 3, startingAt: 1_000)
        let attachment = image("1", width: 400, height: 300)
        harness.setStatuses([withMedia(statuses[0], [attachment])] + statuses.dropFirst())
        let cell = try #require(harness.visibleCell(of: .status(statuses[0].id)))
        let tile = try #require((cell.contentView as? PostContentView)?.mediaGrid?.tile(for: attachment.id))
        let window = try #require(tile.window)
        let list = harness.viewController.collectionView

        let expected = list.convert(list.bounds.inset(by: list.adjustedContentInset), to: window)
        #expect(MediaBarLayering.visibleRect(around: tile, in: window) == expected)
    }

    /// サムネイルの横スクロールの入れ物は、ステータスバーのタップで先頭へ戻る対象にしない。
    /// 画面に対象が複数あるとUIKitはどれも動かさないため、一覧を新着へ戻す操作が効かなくなる。
    @Test func thumbnailContainerDoesNotTakeScrollToTop() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 3, startingAt: 1_000)
        harness.setStatuses([withMedia(statuses[0], [image("1", width: 400, height: 300)])] + statuses.dropFirst())
        let cell = try #require(harness.visibleCell(of: .status(statuses[0].id)))
        let grid = try #require((cell.contentView as? PostContentView)?.mediaGrid)

        let containers = grid.subviews.compactMap { $0 as? UIScrollView }
        #expect(!containers.isEmpty)
        #expect(containers.allSatisfy { !$0.scrollsToTop })
    }

    /// 本文のない投稿は、本文の場所と本文の下の余白を取らず、添付ファイルを上端から置く。上の行との間隔は置く側が決める。
    @Test func mediaStartsAtTopWithoutText() throws {
        let vc = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, mediaImages: .offline)
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let media = try #require(vc.mediaContent(for: withMedia(base, [image("1", width: 100, height: 100)])))
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)

        view.apply(PostBodyContent(text: NSAttributedString(), media: media, mediaSpacing: 8))
        #expect(view.startsWithMedia)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 0)
        let size = view.systemLayoutSizeFitting(CGSize(width: 300, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        #expect(abs(size.height - 300) < 0.5, "高さ\(size.height)")

        view.apply(PostBodyContent(text: NSAttributedString(string: "本文"), media: media, mediaSpacing: 8))
        #expect(!view.startsWithMedia)
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
        let cell = try #require(harness.visibleCell(of: .status(sensitive.id)))
        // 読みに行くかは、レイアウトでタイルの大きさが決まったときに決める。覆っていれば出どころを選ばず、読みに行く処理を始めない。
        let tile = try #require(cell.descendants(of: MediaTileView.self).first)
        #expect(!tile.requestsThumbnail)
        #expect(log.fetched.isEmpty)

        harness.viewController.revealMedia(of: sensitive)
        _ = harness.visibleCell(of: .status(sensitive.id))
        try await waitUntil { !log.fetched.isEmpty }

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

    private func tiles(in view: UIView) -> [MediaTileView] {
        view.subviews.flatMap { subview in (subview as? MediaTileView).map { [$0] } ?? tiles(in: subview) }
    }

    /// 長押ししたサムネイルの、メディアのメニュー。メニューを出さなければnil。
    private func mediaMenu(at tile: MediaTileView, in harness: TimelineHarness, of id: Status.ID) throws -> UIMenu? {
        let vc = harness.viewController
        let cell = try #require(harness.visibleCell(of: .status(id)))
        let entry = try #require(vc.entry(for: .status(id)))
        let point = tile.convert(CGPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: vc.collectionView)
        return vc.mediaMenuTarget(at: point, in: cell).flatMap { vc.mediaMenu(for: $0, entry: entry, id: .status(id)) }
    }

    /// 覆っていないサムネイルを長押しすると、見出しのないメディアのメニューを出し、投稿のメニューを「投稿」に入れる。
    /// 閲覧注意で覆っている間は、中身を見ないまま保存や共有をしないよう出さない。
    @Test func longPressOnTileOffersMediaMenuOnlyWhenUncovered() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let shown = withMedia(statuses[0], [image("1", width: 300, height: 200), image("2", width: 300, height: 200)])
        let sensitive = withMedia(statuses[1], [image("3", width: 300, height: 200)], sensitive: true)
        harness.setStatuses([shown, sensitive] + statuses.dropFirst(2))

        let tile = try #require(mediaGrid(in: harness, of: shown.id)?.tile(for: "2"))
        let menu = try #require(try mediaMenu(at: tile, in: harness, of: shown.id))
        #expect(menu.title.isEmpty)
        #expect(menu.children.contains { ($0 as? UIMenu)?.children.contains { $0.title == "投稿" } == true })

        let coveredGrid = try #require(mediaGrid(in: harness, of: sensitive.id))
        let covered = try #require(tiles(in: coveredGrid).first)
        #expect(try mediaMenu(at: covered, in: harness, of: sensitive.id) == nil)
        #expect(covered.menuAttachment == nil)
    }
}
