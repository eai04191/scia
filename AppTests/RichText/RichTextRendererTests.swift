import Foundation
import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct RichTextRendererTests {
    private let font = UIFont.preferredFont(forTextStyle: .body)

    private func emoji(_ shortcode: String) throws -> CustomEmoji {
        let url = try #require(URL(string: "https://example.social/emoji/\(shortcode).png"))
        return CustomEmoji(shortcode: shortcode, url: url, staticUrl: url)
    }

    private func renderer(_ store: EmojiImageStore, paragraphSpacing: CGFloat = 0) -> RichTextRenderer {
        RichTextRenderer(font: font, textColor: .label, paragraphSpacing: paragraphSpacing, emojiImages: store, language: "ja")
    }

    private func attachments(in string: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    @Test func linksCarryURLAndLinkColor() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let text = RichText(blocks: [.init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), [])])])

        let rendered = renderer(.offline).render(text)
        let linkRange = (rendered.string as NSString).range(of: "example.com/a")

        #expect(rendered.attribute(.linkDestination, at: linkRange.location, effectiveRange: nil) as? RichText.LinkDestination == .url(url))
        #expect(rendered.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? UIColor == .tintColor)
        #expect(rendered.attribute(.linkDestination, at: 0, effectiveRange: nil) == nil)
        // `.link`を付けると、再利用したUILabelが前の内容の色のまま次の本文を描くことがあるため使わない。
        #expect(rendered.attribute(.link, at: linkRange.location, effectiveRange: nil) == nil)
    }

    @Test func appliesParagraphSpacingAndKeepsLineBreakInsideParagraph() throws {
        let text = MastodonHTMLParser(mentions: [], tags: [], emojis: []).parse("<p>a<br>b</p><p>c</p>")

        let rendered = renderer(.offline, paragraphSpacing: 12).render(text)

        #expect(rendered.string == "a\u{2028}b\nc")
        let style = try #require(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.paragraphSpacing == 12)
    }

    @Test func codeBlockLinesStayInOneParagraph() {
        let text = MastodonHTMLParser(mentions: [], tags: [], emojis: []).parse("<pre><code>a\nb</code></pre>")

        #expect(renderer(.offline, paragraphSpacing: 12).render(text).string == "a\u{2028}b")
    }

    @Test func boldUsesBoldFont() throws {
        let rendered = renderer(.offline).render(RichText(blocks: [.init(inlines: [.text("太字", .bold)])]))

        let font = try #require(rendered.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test func emojiShowsPlaceholderWhileLoadingThenImage() async throws {
        let blobcat = try emoji("blobcat")
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { _ in }.pngData())
        let store = EmojiImageStore { _ in png }
        let loaded = LoadRecorder()
        store.addListener(owner: loaded) { urls in loaded.urls.formUnion(urls) }
        let text = RichText.plain(":blobcat:", emojis: [blobcat])

        let first = attachments(in: renderer(store).render(text))
        #expect(first.count == 1)
        #expect(first.first?.bounds.width == first.first?.bounds.height, "読み込み中は正方形の場所を取る")

        for _ in 0..<100 where loaded.urls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(loaded.urls == [blobcat.staticUrl])

        let second = try #require(attachments(in: renderer(store).render(text)).first)
        let bounds = second.bounds
        #expect(abs(bounds.width - bounds.height * 2) < 0.01, "画像の縦横比で並べる")
    }

    @Test func failedEmojiFallsBackToShortcode() async throws {
        let blobcat = try emoji("blobcat")
        let store = EmojiImageStore.offline
        let loaded = LoadRecorder()
        store.addListener(owner: loaded) { urls in loaded.urls.formUnion(urls) }
        let text = RichText.plain("a:blobcat:", emojis: [blobcat])

        _ = renderer(store).render(text)
        for _ in 0..<100 where loaded.urls.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(renderer(store).render(text).string == "a:blobcat:")
    }
}

@MainActor
private final class LoadRecorder {
    var urls: Set<URL> = []
}
