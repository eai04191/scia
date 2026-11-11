import SciaCore
import SciaTesting
import Testing
import TextKit2Label
import UIKit
@testable import Scia

/// 引用の囲みの本文の並べ方。投稿の本文と同じくTextKit 2で描き、大きくした絵文字の行を絵の高さにする。
@Suite(.scratch, .failureState)
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

    /// 本文が訳文に替わって高さが変わるとき、本文より下の部品と囲みの下端は、一度に移らず、前の位置から動く。
    @Test func partsBelowTextMoveWhenTranslationChangesHeight() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.isHidden = false
        let view = laidOut(translating("short", isTranslated: false))
        window.addSubview(view)
        let height = view.bounds.height

        view.apply(translating(String(repeating: "訳文が長くなって行が増える。", count: 6), isTranslated: true))
        view.frame.size = view.systemLayoutSizeFitting(CGSize(width: 328, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.layoutIfNeeded()

        #expect(view.bounds.height > height + 10)
        #expect(view.subviews.filter { shiftCount(of: $0.layer) > 0 }.count == 1)
        #expect(shiftCount(of: view.layer) == 2)

        // 動きの途中に原文へ戻すと、前の動きを消さずに足し合わせる。消すと、残っていた分だけ跳ねる。
        view.apply(translating("short", isTranslated: false))
        view.frame.size = view.systemLayoutSizeFitting(CGSize(width: 328, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        view.layoutIfNeeded()

        #expect(view.subviews.map { shiftCount(of: $0.layer) }.max() == 2)
        #expect(shiftCount(of: view.layer) == 4)

        // 使い回されて別の囲みに替わったら、前の囲みの動きを残さない。
        var other = translating("other", isTranslated: false)
        other.id = "quote-2"
        view.apply(other)

        #expect(view.subviews.allSatisfy { shiftCount(of: $0.layer) == 0 })
        #expect(shiftCount(of: view.layer) == 0)
    }

    private func shiftCount(of layer: CALayer) -> Int {
        (layer.animationKeys() ?? []).filter { $0.hasPrefix("textReplacementShift") }.count
    }

    private func translating(_ string: String, isTranslated: Bool) -> EmbeddedPostView.Content {
        let renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: .offline, language: "ja")
        var content = embed(text: renderer.render(.plain(string, emojis: [])))
        content.notes = [EmbeddedPostView.Content.Note(text: NSAttributedString(string: "投票", attributes: [.font: font]), isPressable: false)]
        content.translation = EmbeddedPostView.Content.Translation(isTranslated: isTranslated, wipeDuration: 0.3, shiftDuration: 0.3, wordDuration: 0.1, fadeWidth: 10, markScale: 1)
        return content
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

    /// 大きくした絵文字が、最初の段落の折り返したあとの行にだけあれば、サムネイルの上端は、絵文字のない1行目の字面の上端にそろえる。
    /// TextKit 2は行ごとに高さを決めるので、1行目は絵文字に合わせて高くならない。
    @Test func besideMediaTopIgnoresLargeEmojiInWrappedLine() throws {
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
        var renderer = RichTextRenderer(font: font, textColor: .label, emojiImages: .offline, language: "ja")
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(.plain(String(repeating: "文", count: 60) + "😀", emojis: []))

        let view = laidOut(embed(text: text, media: media))
        let grid = try #require(view.mediaGrid)
        let padding: CGFloat = 10
        let textWidth = view.bounds.width - padding * 2 - grid.bounds.width - 8
        let style = TextKitLabelLayout.Style(font: font, textColor: .label, lineBreakMode: .byWordWrapping, direction: .leftToRight, displayScale: view.traitCollection.displayScale, overlaysGlyphs: true)
        let layout = TextKitLabelLayout.layout(of: TextKitLabelLayout.filled(text, style: style), width: textWidth, maximumLines: 0, style: style)
        let metrics = try #require(TextKitLabelLayout.metrics(of: layout, displayScale: view.traitCollection.displayScale))

        try #require(metrics.lineCount > 1)
        #expect(abs(grid.frame.minY - (padding + metrics.firstBaseline - font.pointSize * PostBodyView.emBoxAscent)) < 0.5)
    }
}
