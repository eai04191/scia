import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 引用の囲みの本文の並べ方。投稿の本文と同じくTextKit 2で描き、大きくした絵文字の行を絵の高さにする。
@Suite(.scratch)
@MainActor
struct EmbeddedPostTextTests {
    private let font = UIFont.preferredFont(forTextStyle: .body)

    private func embed(text: NSAttributedString, media: MediaGridView.Content? = nil) -> EmbeddedPostView.Content {
        var content = EmbeddedPostView.Content(
            id: "quote-1",
            header: nil,
            avatarSize: 20,
            text: text,
            openActionName: "開く",
            padding: 10,
            avatarNameSpacing: 6,
            headerSpacing: 6,
            mediaSpacing: 8,
            transitionDuration: 0.4
        )
        content.media = media
        return content
    }

    private func laidOut(_ content: EmbeddedPostView.Content, width: CGFloat = 328) -> EmbeddedPostView {
        let view = EmbeddedPostView(store: .offline, avatarImages: .offline)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.apply(content)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.frame.size = view.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.layoutIfNeeded()
        return view
    }

    /// 大きくしたUnicodeの絵文字の本文は、同じ大きさのカスタム絵文字の本文と同じ高さになる。
    @Test func largeUnicodeEmojiBodyIsAsTallAsCustomEmojiBody() throws {
        let url = try #require(URL(string: "https://example.social/emoji/a.png"))
        let parser = MastodonHTMLParser(mentions: [], tags: [], emojis: [CustomEmoji(shortcode: "a", url: url, staticUrl: url)])
        var unicode = RichTextRenderer(font: font, textColor: .label, emojiImages: .offline, language: "ja")
        unicode.unicodeEmojiScale = 2
        var custom = RichTextRenderer(font: font, textColor: .label, emojiImages: .offline, language: "ja")
        custom.emojiScale = 2

        let unicodeHeight = laidOut(embed(text: unicode.render(parser.parse("<p>文😀文<br>次の行</p>")))).bounds.height
        let customHeight = laidOut(embed(text: custom.render(parser.parse("<p>文:a:文<br>次の行</p>")))).bounds.height

        #expect(abs(unicodeHeight - customHeight) < 1, "\(unicodeHeight) \(customHeight)")
    }

    /// 本文の右に出すサムネイルの上端は、本文の1行目の字面の上端にそろえる。
    @Test func besideMediaTopAlignsWithFirstLine() throws {
        let attachment = MediaAttachment(
            id: "1",
            type: .image,
            url: URL(string: "https://files.example.social/original/1.png"),
            previewUrl: URL(string: "https://files.example.social/small/1.png"),
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 400, height: 300)),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        )
        var media = MediaGridView.Content(attachments: [attachment], cover: nil, tallestAspectRatio: 0.75, thumbnailPolicy: .offline, spacing: 4)
        media.arrangement = .stack(side: 64)
        let text = RichTextRenderer(font: font, textColor: .label, emojiImages: .offline, language: "ja").render(.plain("本文の1行目", emojis: []))

        let view = laidOut(embed(text: text, media: media))
        let grid = try #require(view.mediaGrid)
        let padding: CGFloat = 10
        let textWidth = view.bounds.width - padding * 2 - grid.bounds.width - 8
        let style = TextKitLabelLayout.Style(font: font, textColor: .label, lineBreakMode: .byWordWrapping, direction: .leftToRight, displayScale: view.traitCollection.displayScale, overlaysGlyphs: true)
        let layout = TextKitLabelLayout.layout(of: TextKitLabelLayout.filled(text, style: style), width: textWidth, maximumLines: 0, style: style)
        let firstBaseline = try #require(TextKitLabelLayout.metrics(of: layout, displayScale: view.traitCollection.displayScale)).firstBaseline

        #expect(abs(grid.frame.minY - (padding + firstBaseline - PostBodyView.textTopInset(of: text))) < 0.5)
    }
}
