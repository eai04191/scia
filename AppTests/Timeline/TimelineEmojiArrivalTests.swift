import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// カスタム絵文字の画像が届いたら、その絵文字を描く行を再描画する。
@MainActor
@Suite(.scratch, .serialized, .failureState)
struct TimelineEmojiArrivalTests {
    private func emoji(_ name: String) throws -> CustomEmoji {
        CustomEmoji(
            shortcode: name,
            url: try #require(URL(string: "https://example.social/emojis/\(name).png")),
            staticUrl: try #require(URL(string: "https://example.social/emojis/\(name)-static.png"))
        )
    }

    private func status(_ base: Status, emoji: CustomEmoji) -> Status {
        Status(id: base.id, createdAt: base.createdAt, account: base.account, content: "<p>:\(emoji.shortcode):</p>", spoilerText: "", url: nil, emojis: [emoji])
    }

    /// 本文の絵文字が、読み込み中の空き（`emojiPlaceholder`）でなく画像で描かれているか。
    private func showsImage(in harness: TimelineHarness, of id: Status.ID) -> Bool {
        guard let body = ((harness.visibleCell(of: .status(id))?.contentView as? PostContentView)?.configuration as? PostContentConfiguration)?.body else { return false }
        var image: UIImage?
        body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment, attachment.image !== RichTextRenderer.emojiPlaceholder {
                image = attachment.image
            }
        }
        return image != nil
    }

    /// 行が入れ替わったあとに届いた画像でも、それを描く新しい行を再描画する。届いた画像のURLから行を引く索引を、行が変わったら作り直すため。
    @Test func redrawsRowsAddedAfterEarlierArrivals() async throws {
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }.pngData())
        let store = EmojiImageStore<UIImage> { _ in png }
        let harness = try TimelineHarness(emojiImages: store)
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        statuses[0] = status(statuses[0], emoji: try emoji("first"))
        harness.setStatuses(statuses)
        try await waitUntil { showsImage(in: harness, of: statuses[0].id) }

        let added = status(StatusFactory.make(count: 1, startingAt: 2_000)[0], emoji: try emoji("second"))
        harness.setStatuses([added] + statuses)

        try await waitUntil { showsImage(in: harness, of: added.id) }
    }

    /// 画像が届いても、その絵文字を描かない行は再描画しない。
    @Test func leavesRowsWithoutArrivedEmoji() async throws {
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }.pngData())
        let store = EmojiImageStore<UIImage> { _ in png }
        let harness = try TimelineHarness(emojiImages: store)
        defer { harness.tearDown() }
        var statuses = StatusFactory.make(count: 10, startingAt: 1_000)
        statuses[0] = status(statuses[0], emoji: try emoji("first"))
        harness.setStatuses(statuses)
        let other = try #require((harness.visibleCell(of: .status(statuses[1].id))?.contentView as? PostContentView)?.configuration as? PostContentConfiguration)

        try await waitUntil { showsImage(in: harness, of: statuses[0].id) }

        let after = try #require((harness.visibleCell(of: .status(statuses[1].id))?.contentView as? PostContentView)?.configuration as? PostContentConfiguration)
        #expect(after.body === other.body, "絵文字のない行を描き直しています")
    }
}
