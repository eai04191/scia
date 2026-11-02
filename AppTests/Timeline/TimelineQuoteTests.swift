import SciaCore
import Testing
import SciaTesting
import UIKit
@testable import Scia

/// 投稿の中の引用の囲みを確かめる。決まりは`docs/quote.md`。
@MainActor
@Suite(.scratch, .serialized)
struct TimelineQuoteTests {
    private let quotedAccount = Account(id: "9", username: "bob", acct: "bob@remote.example", displayName: "Bob", avatar: URL(string: "https://remote.example/a.png"))

    private func quoted(_ id: String, spoilerText: String = "", media: [MediaAttachment] = []) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: quotedAccount, content: "<p>引用元の本文</p>", spoilerText: spoilerText, url: nil, mediaAttachments: media, sensitive: !media.isEmpty)
    }

    private func quoting(_ base: Status, _ quote: Quote) -> Status {
        Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: #"<p class="quote-inline">RE: <a href="https://remote.example/@bob/1">remote.example/@bob/1</a></p><p>引用した本文</p>"#,
            spoilerText: "",
            url: nil,
            quote: quote
        )
    }

    private func post(in harness: TimelineHarness, of id: Status.ID) -> PostContentView? {
        harness.visibleCell(of: .status(id))?.contentView as? PostContentView
    }

    private func configuration(in harness: TimelineHarness, of id: Status.ID) -> PostContentConfiguration? {
        post(in: harness, of: id)?.configuration as? PostContentConfiguration
    }

    /// 引用元を囲みで出し、本文からは互換のための`RE: <リンク>`を除く。
    @Test func showsQuotedStatusAndDropsQuoteInline() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let status = quoting(statuses[0], Quote(state: "accepted", quotedStatus: quoted("q1")))
        harness.setStatuses([status] + statuses.dropFirst())

        let configuration = try #require(configuration(in: harness, of: status.id))
        #expect(configuration.body.string == "引用した本文")
        let embed = try #require(configuration.embed)
        #expect(embed.header?.name.string.contains("Bob") == true)
        #expect(embed.text.string == "引用元の本文")
        #expect(embed.isPressable)
        #expect(post(in: harness, of: status.id)?.embed != nil)
    }

    /// 出せない引用元は、作者の行を出さずに理由だけを出し、押下を受けずに行へ渡す。
    @Test func unavailableQuoteIsPlaceholderPassingTouchesToRow() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let status = quoting(statuses[0], Quote(state: "deleted"))
        harness.setStatuses([status] + statuses.dropFirst())

        let configuration = try #require(configuration(in: harness, of: status.id))
        let embed = try #require(configuration.embed)
        #expect(embed.header == nil)
        #expect(embed.text.string == "引用元の投稿は削除されました")
        #expect(!embed.isPressable)
        let view = try #require(post(in: harness, of: status.id)?.embed)
        #expect(view.hitTest(CGPoint(x: view.bounds.midX, y: view.bounds.midY), with: nil) == nil)
    }

    /// ミュートしている人の引用元は、押して開くまで出さない。開いても、押した行の画面上の位置は動かない。
    @Test func revealingMutedQuoteKeepsRowPosition() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let status = quoting(statuses[1], Quote(state: "muted_account", quotedStatus: quoted("q1")))
        harness.setStatuses([statuses[0], status] + statuses.dropFirst(2))
        try harness.scroll(to: .status(status.id), at: .centeredVertically)
        let y = try #require(harness.windowMinY(of: .status(status.id)))
        #expect(configuration(in: harness, of: status.id)?.embed?.header == nil)

        harness.viewController.revealQuote(of: status, keeping: .status(status.id))

        #expect(configuration(in: harness, of: status.id)?.embed?.header != nil)
        #expect(harness.windowMinY(of: .status(status.id)) == y)
    }

    /// 引用元の注意書きは、引用元の投稿ごとに開閉し、囲みの中で本文を出し入れする。開閉しても、押した行の画面上の位置は動かない。
    @Test func togglingQuotedSpoilerExpandsInsideEmbed() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let source = quoted("q1", spoilerText: "ネタバレ")
        let status = quoting(statuses[1], Quote(state: "accepted", quotedStatus: source))
        harness.setStatuses([statuses[0], status] + statuses.dropFirst(2))
        try harness.scroll(to: .status(status.id), at: .centeredVertically)
        let y = try #require(harness.windowMinY(of: .status(status.id)))
        #expect(configuration(in: harness, of: status.id)?.embed?.spoiler?.isCollapsed == true)

        harness.viewController.toggleSpoiler(of: source, keeping: .status(status.id))

        #expect(configuration(in: harness, of: status.id)?.embed?.spoiler?.isCollapsed == false)
        #expect(harness.windowMinY(of: .status(status.id)) == y)
    }

    /// 引用元の閲覧注意の画像は、引用元の投稿のぼかしとして外し、引用している行を描き直す。
    @Test func revealingQuotedMediaRedrawsQuotingRow() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let image = MediaAttachment(
            id: "m1",
            type: .image,
            url: URL(string: "https://files.example.social/original/m1.png"),
            previewUrl: URL(string: "https://files.example.social/small/m1.png"),
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 400, height: 300))
        )
        let source = quoted("q1", media: [image])
        let status = quoting(statuses[0], Quote(state: "accepted", quotedStatus: source))
        harness.setStatuses([status] + statuses.dropFirst())
        #expect(configuration(in: harness, of: status.id)?.embed?.media?.isCovered == true)

        harness.viewController.revealMedia(of: source)

        #expect(configuration(in: harness, of: status.id)?.embed?.media?.isCovered == false)
    }

    /// 投稿の添付ファイルを本文の右に重ねる並べ方でも、引用とXの投稿を本文の下にする設定なら、引用元の添付ファイルは本文の下に並べる。
    @Test func quotedMediaStaysBelowBodyWhenEmbedsAreBelow() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.appearance.mediaArrangement = .besideBody
        harness.settings.appearance.embedMediaArrangement = .belowBody
        let status = quotingImage(in: harness)

        #expect(configuration(in: harness, of: status.id)?.embed?.media?.arrangement == .grid)
    }

    /// 投稿の添付ファイルを本文の下に並べていても、引用とXの投稿を本文の右にする設定なら、引用元の添付ファイルだけを重ねて出す。
    @Test func quotedMediaIsBesideBodyWhilePostMediaIsBelow() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.appearance.mediaArrangement = .belowBody
        harness.settings.appearance.embedMediaArrangement = .besideBody
        let status = quotingImage(in: harness)

        let side = harness.settings.value(of: AppearanceCatalog.mediaBesideSide)
        #expect(configuration(in: harness, of: status.id)?.embed?.media?.arrangement == .stack(side: side))
    }

    /// 投稿と同じ並べ方の既定で、投稿を本文の右にしていれば、引用元の添付ファイルも囲みの本文の右に重ね、本文はその分をあけて折り返す。囲みはサムネイルの分だけ伸びる。
    @Test func quotedMediaFollowsPostBesideBodyByDefault() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.appearance.mediaArrangement = .besideBody
        let status = quotingImage(in: harness)

        let content = try #require(configuration(in: harness, of: status.id)?.embed)
        let side = harness.settings.value(of: AppearanceCatalog.mediaBesideSide)
        #expect(content.media?.arrangement == .stack(side: side))
        #expect(content.media?.stackSeed == "q1")
        let embed = try #require(post(in: harness, of: status.id)?.embed)
        embed.layoutIfNeeded()
        let grid = try #require(embed.mediaGrid)
        let body = try #require(embed.subviews.first { $0 is LinkLabel && !$0.isHidden })
        #expect(grid.frame.size == CGSize(width: side, height: side))
        #expect(abs(grid.frame.maxX - (embed.bounds.width - content.padding)) < 0.5)
        #expect(body.frame.maxX <= grid.frame.minX - content.mediaSpacing + 0.5, "本文がサムネイルの分をあけていません")
        #expect(grid.frame.minY < body.frame.maxY, "サムネイルが本文の横に並んでいません")
        #expect(embed.bounds.height >= grid.frame.maxY + content.padding - 0.5, "囲みがサムネイルの分だけ伸びていません")
    }

    /// 右に並べる大きさと本文とのあいだを上限にしても、囲みの中のサムネイルとすき間は囲みの内側の半分までに縮め、本文の幅を残す。
    @Test func quotedBesideMediaLeavesRoomForBody() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.settings.appearance.mediaArrangement = .besideBody
        harness.settings.setValue(AppearanceCatalog.mediaBesideSide.range.upperBound, for: AppearanceCatalog.mediaBesideSide)
        harness.settings.setValue(AppearanceCatalog.xPostMediaSpacing.range.upperBound, for: AppearanceCatalog.xPostMediaSpacing)
        let status = quotingImage(in: harness)

        let content = try #require(configuration(in: harness, of: status.id)?.embed)
        let embed = try #require(post(in: harness, of: status.id)?.embed)
        embed.layoutIfNeeded()
        let grid = try #require(embed.mediaGrid)
        let body = try #require(embed.subviews.first { $0 is LinkLabel && !$0.isHidden })
        let inner = embed.bounds.width - content.padding * 2
        #expect(grid.frame.width == grid.frame.height)
        #expect(grid.frame.width + content.mediaSpacing <= inner / 2 + 0.5, "サムネイルとすき間が囲みの内側の半分を超えています")
        #expect(abs(body.frame.width - (inner - grid.frame.width - content.mediaSpacing)) < 0.5, "本文がサムネイルの分だけをあけていません")
    }

    /// 引用元に画像を1つ付けた投稿を一覧の一番上に流す。
    private func quotingImage(in harness: TimelineHarness) -> Status {
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let image = MediaAttachment(
            id: "m1",
            type: .image,
            url: URL(string: "https://files.example.social/original/m1.png"),
            previewUrl: URL(string: "https://files.example.social/small/m1.png"),
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 400, height: 300))
        )
        let status = quoting(statuses[0], Quote(state: "accepted", quotedStatus: quoted("q1", media: [image])))
        harness.setStatuses([status] + statuses.dropFirst())
        return status
    }

    /// 引用元がさらに引用していると、その引用はIDだけで届く。囲みを押したら、引用元を読み直す経路で開き、スレッドで入れ子の引用を出せるようにする。
    @Test func openingQuotedStatusWithNestedQuoteFetchesItFirst() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let plain = quoting(statuses[0], Quote(state: "accepted", quotedStatus: quoted("q1")))
        let nestedSource = Status(id: "q2", createdAt: Date(timeIntervalSince1970: 0), account: quotedAccount, content: "<p>入れ子</p>", spoilerText: "", url: nil, quote: Quote(state: "accepted", quotedStatusID: "q3"))
        let nested = quoting(statuses[1], Quote(state: "accepted", quotedStatus: nestedSource))
        harness.setStatuses([plain, nested] + statuses.dropFirst(2))
        var openedThreads: [Status.ID] = []
        var fetchedIDs: [Status.ID] = []
        harness.viewController.onOpenThread = { status, _ in openedThreads.append(status.id) }
        harness.viewController.onOpenStatusID = { id, _ in fetchedIDs.append(id) }

        try #require(post(in: harness, of: plain.id)?.embed).sendActions(for: .primaryActionTriggered)
        try #require(post(in: harness, of: nested.id)?.embed).sendActions(for: .primaryActionTriggered)

        #expect(openedThreads == ["q1"])
        #expect(fetchedIDs == ["q2"])
    }

    /// 引用元にだけある絵文字の画像が届いたときも、引用している行を描き直す。
    @Test func emojiURLsIncludeQuotedStatus() throws {
        let emoji = CustomEmoji(shortcode: "q", url: try #require(URL(string: "https://remote.example/q.png")), staticUrl: try #require(URL(string: "https://remote.example/q-static.png")))
        let source = Status(id: "q1", createdAt: Date(timeIntervalSince1970: 0), account: quotedAccount, content: "<p>:q:</p>", spoilerText: "", url: nil, emojis: [emoji])
        let status = quoting(StatusFactory.make(count: 1, startingAt: 1_000)[0], Quote(state: "accepted", quotedStatus: source))

        #expect(TimelineViewController.emojiURLs(of: status, quoteSources: QuoteSourceChanges()).contains(emoji.staticUrl))
        // 引用元の編集で足された絵文字も含める。
        let added = CustomEmoji(shortcode: "a", url: try #require(URL(string: "https://remote.example/a.png")), staticUrl: try #require(URL(string: "https://remote.example/a-static.png")))
        var changes = QuoteSourceChanges()
        changes.edit(Status(id: "q1", createdAt: source.createdAt, account: quotedAccount, content: "<p>:a:</p>", spoilerText: "", url: nil, emojis: [added], editedAt: Date(timeIntervalSince1970: 10)))
        #expect(TimelineViewController.emojiURLs(of: status, quoteSources: changes).contains(added.staticUrl))
    }

    /// 承認待ちだった引用を取り直して、承認された引用元の囲みに替わるときは、docs/vision.mdの「一覧の動き」のとおり伸ばす。
    /// 上端が表示領域より上にある行は画面上の位置を保ち、下の行は元の位置から新しい位置へ動かす。
    @Test func refreshedQuoteGrowsRowWithMotion() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 30, startingAt: 1_000)
        let base = statuses[10]
        statuses[10] = quoting(base, Quote(state: "pending"))
        harness.setStatuses(statuses)
        let id = TimelineViewController.ItemID.status(base.id)
        try harness.scroll(to: id, at: .top)
        harness.collectionView.contentOffset.y += 20
        harness.collectionView.layoutIfNeeded()
        let y = try #require(harness.windowMinY(of: id))
        let height = try #require(harness.visibleCell(of: id)?.frame.height)
        let belowCell = try #require(harness.visibleCell(of: .status(statuses[11].id)))

        statuses[10] = quoting(base, Quote(state: "accepted", quotedStatus: quoted("q1")))
        harness.viewController.refreshedStatusID = base.id
        harness.setStatuses(statuses)
        harness.viewController.refreshedStatusID = nil

        #expect(configuration(in: harness, of: base.id)?.embed?.text.string == "引用元の本文")
        #expect(try #require(harness.visibleCell(of: id)?.frame.height) > height, "囲みに替わって行が伸びていません")
        #expect(harness.windowMinY(of: id) == y)
        #expect(belowCell.layer.animationKeys()?.contains { $0.hasPrefix("rowShift") } == true, "下の行を動かしていません")
    }

    /// 引用元の編集と削除、読み込んだあとのミュートを受け取ると、引用している行の囲みを描き直す。
    @Test func sourceChangesRedrawQuotingRows() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        let source = quoted("q1")
        let status = quoting(statuses[0], Quote(state: "accepted", quotedStatus: source))
        harness.setStatuses([status] + statuses.dropFirst())
        let vc = harness.viewController
        var changes = QuoteSourceChanges()

        changes.edit(Status(id: "q1", createdAt: source.createdAt, account: quotedAccount, content: "<p>直した本文</p>", spoilerText: "", url: nil, editedAt: Date(timeIntervalSince1970: 10)))
        vc.applyQuoteSourceChanges(changes, affecting: .status("q1"))
        #expect(configuration(in: harness, of: status.id)?.embed?.text.string == "直した本文")

        changes.setAccount(quotedAccount.id, concealedAs: .mutedAccount)
        vc.applyQuoteSourceChanges(changes, affecting: .account(quotedAccount.id))
        #expect(configuration(in: harness, of: status.id)?.embed?.text.string.hasPrefix("ミュートしている人の投稿です") == true)

        changes.delete("q1")
        vc.applyQuoteSourceChanges(changes, affecting: .status("q1"))
        #expect(configuration(in: harness, of: status.id)?.embed?.text.string == "引用元の投稿は削除されました")
        // 引用している投稿は残す。
        #expect(configuration(in: harness, of: status.id)?.body.string == "引用した本文")
    }
}
