import Foundation
import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct LinkLabelTests {
    private func label(for text: RichText, width: CGFloat = 300) -> LinkLabel {
        let renderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: .offline, language: "ja")
        let label = LinkLabel()
        label.numberOfLines = 0
        label.attributedText = renderer.render(text)
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        label.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        return label
    }

    /// 文字列`substring`の、描いた位置の中央。
    private func center(of substring: String, in label: LinkLabel) throws -> CGPoint {
        let attributed = try #require(label.attributedText)
        let range = (attributed.string as NSString).range(of: substring)
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    @Test func findsLinkUnderPoint() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let profile = try #require(URL(string: "https://example.social/@bob"))
        let text = RichText(blocks: [
            .init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), []), .text(" と ", []), .link("@bob", .mention(acct: "bob@example.social", url: profile), [])]),
        ])
        let label = label(for: text)

        #expect(label.link(at: try center(of: "example.com/a", in: label)) == .url(url))
        #expect(label.link(at: try center(of: "@bob", in: label)) == .mention(acct: "bob@example.social", url: profile))
        #expect(label.link(at: try center(of: "見て", in: label)) == nil)
    }

    /// 行末より右を押しても、近くのリンクを押したことにしない。
    @Test func ignoresPointPastLineEnd() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let text = RichText(blocks: [.init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), [])])])
        let label = label(for: text)
        let link = try center(of: "example.com/a", in: label)

        #expect(label.link(at: CGPoint(x: label.bounds.maxX - 1, y: link.y)) == nil)
    }

    /// MacのDesigned for iPadでは、アクティブでないウィンドウへの最初のクリックを、押された場所のビューが`UIControl`のときだけ通す。
    /// リンクの上では`UIControl`に当たり、リンクの外ではラベルに当たって後ろのセルへ渡ることを確かめる。
    @Test func hitsControlOnlyOverLink() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let text = RichText(blocks: [.init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), [])])])
        let label = label(for: text)

        let onLink = label.hitTest(try center(of: "example.com/a", in: label), with: nil)
        #expect(onLink is UIControl)
        #expect(onLink !== label)
        #expect(label.hitTest(try center(of: "見て", in: label), with: nil) === label)
    }

    /// 文字列や幅が変わったら、前に並べた結果を使わずに並べ直す。
    @Test func relayoutsAfterTextOrWidthChange() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let label = label(for: RichText(blocks: [.init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), [])])]))
        let link = try center(of: "example.com/a", in: label)
        #expect(label.link(at: link) == .url(url))

        let renderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: .offline, language: "ja")
        label.attributedText = renderer.render(RichText(blocks: [.init(inlines: [.text("リンクのない本文です。リンクのない本文です。", [])])]))
        #expect(label.link(at: link) == nil)

        // 幅を狭めて、リンクを3行目より下へ折り返させる。
        label.attributedText = renderer.render(RichText(blocks: [.init(inlines: [.text("見て見て見て見て見て見て見て見て ", []), .link("abc", .url(url), [])])]))
        #expect(label.link(at: try center(of: "abc", in: label)) == .url(url))
        let narrow = label.sizeThatFits(CGSize(width: 60, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(origin: .zero, size: CGSize(width: 60, height: narrow.height))
        let wrapped = try center(of: "abc", in: label)
        #expect(label.link(at: wrapped) == .url(url))
    }

    /// リンクを押して少し止めてから引いても、タイムラインと編集履歴はスクロールに切り替える。
    @Test func scrollViewsCancelLinkTouches() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let label = label(for: RichText(blocks: [.init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), [])])]))
        let hitArea = try #require(label.hitTest(try center(of: "example.com/a", in: label), with: nil))

        #expect(TimelineCollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout()).touchesShouldCancel(in: hitArea))
        #expect(EditHistoryScrollView().touchesShouldCancel(in: hitArea))
        #expect(!UIScrollView().touchesShouldCancel(in: hitArea))
    }
}
