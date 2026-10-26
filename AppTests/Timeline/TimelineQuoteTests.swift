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
