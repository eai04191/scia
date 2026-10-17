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
}
