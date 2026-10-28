import CoreText
import Foundation
import SciaCore
import SciaTesting
import Synchronization
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

    /// 本文の絵文字が通信の失敗で読めなかったら文字で描き、間隔が過ぎてから描き直すと、描くことで読み直しが始まり、読めたら画像で描く。
    @Test func failedEmojiIsRetriedWhenTheTextIsDrawnAgain() async throws {
        let clock = TestClock()
        let reads = Mutex(0)
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.pngData())
        let store = EmojiImageStore(clock: clock, retryPolicy: { RetrySchedule.Policy(initialDelay: .seconds(5), maxDelay: .seconds(60)) }) { _ in
            let read = reads.withLock { reads in
                defer { reads += 1 }
                return reads
            }
            if read == 0 { throw URLError(.notConnectedToInternet) }
            return png
        }
        let emoji = try emoji("ok")
        let text = RichText(blocks: [.init(inlines: [.emoji(emoji)])])

        _ = renderer(store).render(text)
        try await waitUntil { store.hasFailed(emoji.staticUrl) }
        #expect(renderer(store).render(text).string == ":ok:")
        #expect(reads.withLock { $0 } == 1)

        clock.advance(by: .seconds(5))
        #expect(renderer(store).render(text).string == ":ok:", "読み直している間に文字で描かなくなりました")
        try await waitUntil { !store.hasFailed(emoji.staticUrl) }
        #expect(reads.withLock { $0 } == 2)
        #expect(attachments(in: renderer(store).render(text)).count == 1)
    }

    private func attachments(in string: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    /// 文字列を並べたときに、それぞれの文字を描く書体のファミリー名。
    private func fontFamilies(of string: NSAttributedString) -> [String: String] {
        glyphRuns(of: string).mapValues(\.family)
    }

    /// 文字列を並べたときの、書体ごとのまとまりの書体のファミリー名と字形の数。
    private func glyphRuns(of string: NSAttributedString) -> [String: (family: String, glyphs: Int)] {
        let line = CTLineCreateWithAttributedString(string)
        var result: [String: (family: String, glyphs: Int)] = [:]
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let range = CTRunGetStringRange(run)
            let text = (string.string as NSString).substring(with: NSRange(location: range.location, length: range.length))
            let attributes = CTRunGetAttributes(run) as NSDictionary
            if let font = attributes[kCTFontAttributeName] {
                // swiftlint:disable:next force_cast
                result[text] = (CTFontCopyFamilyName(font as! CTFont) as String, CTRunGetGlyphCount(run))
            }
        }
        return result
    }

    @Test func twemojiDrawsEmojiButKeepsTextSymbolsInSystemFont() {
        // ZWJの並びは、U+FE0Fの付け方がtwemojiのファイル名と違っても、1つの絵で描く。
        let text = RichText(blocks: [.init(inlines: [
            .text("a😀", []), .text("©", []), .text("👨‍👩‍👧", []), .text(" 🏃\u{200D}♀ ", []), .text("👁\u{FE0F}\u{200D}🗨\u{FE0F}", []),
        ])])

        let twemoji = glyphRuns(of: RichTextRenderer(font: font, textColor: .label, emojiImages: .offline, language: "ja", emojiStyle: .twemoji).render(text))
        #expect(twemoji["😀"]?.family == "Twemoji")
        for sequence in ["👨‍👩‍👧", "🏃\u{200D}♀", "👁\u{FE0F}\u{200D}🗨\u{FE0F}"] {
            #expect(twemoji[sequence]?.family == "Twemoji")
            #expect(twemoji[sequence]?.glyphs == 1, "\(sequence)が1つの絵にならない")
        }
        #expect(twemoji["©"]?.family != "Twemoji")

        let system = fontFamilies(of: RichTextRenderer(font: font, textColor: .label, emojiImages: .offline, language: "ja", emojiStyle: .system).render(text))
        #expect(system["😀"]?.contains("Apple Color Emoji") == true)
    }

    /// twemojiは文字で描く指定（U+FE0E）を区別せず、キーキャップの部品の数字を空の字形で持つため、これらの並びはtwemojiで描かない。
    @Test func twemojiKeepsTextPresentationAndBareKeycapBases() {
        let sequences = ["☺\u{FE0E}", "1\u{FE0F}", "#\u{FE0F}", "1\u{FE0F}\u{20E3}", "☺\u{FE0F}"]
        let rendered = RichTextRenderer(font: font, textColor: .label, emojiImages: .offline, language: "ja", emojiStyle: .twemoji)
            .render(RichText(blocks: [.init(inlines: [.text(sequences.joined(separator: " "), [])])]))

        let line = CTLineCreateWithAttributedString(rendered)
        func family(of sequence: String) -> String? {
            let location = (rendered.string as NSString).range(of: sequence).location
            for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
                let range = CTRunGetStringRange(run)
                guard range.location <= location, location < range.location + range.length,
                      let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName]
                else { continue }
                // swiftlint:disable:next force_cast
                return CTFontCopyFamilyName(font as! CTFont) as String
            }
            return nil
        }
        #expect(family(of: "☺\u{FE0E}") != "Twemoji")
        #expect(family(of: "1\u{FE0F} ") != "Twemoji")
        #expect(family(of: "#\u{FE0F}") != "Twemoji")
        #expect(family(of: "1\u{FE0F}\u{20E3}") == "Twemoji")
        #expect(family(of: "☺\u{FE0F}") == "Twemoji")
        #expect(family(of: "☺\u{FE0E}") != nil)
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

        try await waitUntil { !loaded.urls.isEmpty }
        #expect(loaded.urls == [blobcat.staticUrl])

        let second = try #require(attachments(in: renderer(store).render(text)).first)
        let bounds = second.bounds
        #expect(abs(bounds.width - bounds.height * 2) < 0.01, "画像の縦横比で並べる")
    }

    /// 編集履歴で消したり足したりした絵文字は、背景まで塗った不透明な画像でも見分けられるようにする。
    /// 赤や緑の地と取り消し線は絵文字の画像の下に描かれるので、消した絵文字は薄く描いて透かして動かさず、足した絵文字は画像に緑を重ね、動く層にも重ねる色を渡す。
    @Test func changedEmojiInDiffStaysVisiblyMarked() async throws {
        let gone = try emoji("gone")
        let added = try emoji("added")
        let kept = try emoji("kept")
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }.pngData())
        let store = EmojiImageStore { _ in png }
        let emojis = [gone, added, kept]
        _ = renderer(store).render(RichText.plain(":gone: :added: :kept:", emojis: emojis))
        try await waitUntil { emojis.allSatisfy { store.image(for: $0.staticUrl) != nil } }
        let diff = RichTextDiff(
            old: RichText.plain("前 :gone: 中 :kept: 後", emojis: emojis),
            new: RichText.plain("前 :added: 中 :kept: 後", emojis: emojis),
            minimumUnchangedRatio: 0
        )

        let rendered = renderer(store).render(diff)
        let images = try attachments(in: rendered).map { try #require($0.image) }
        try #require(images.count == 3)
        let removed = try centerPixel(of: images[0])
        let inserted = try centerPixel(of: images[1])
        let unchanged = try centerPixel(of: images[2])
        #expect(removed.alpha < 128, "消した絵文字は、下の赤い地と取り消し線が透けるよう薄く描く")
        #expect(inserted.green > inserted.red && inserted.alpha == 255, "足した絵文字は、画像に緑を重ねる")
        #expect(unchanged.red == 255 && unchanged.green == 255, "変わっていない絵文字はそのまま")
        var animated: [Int] = []
        rendered.enumerateAttribute(.customEmoji, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            if value != nil { animated.append(contentsOf: range.location..<NSMaxRange(range)) }
        }
        var tinted: [Int] = []
        rendered.enumerateAttribute(.emojiTint, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            if value != nil { tinted.append(contentsOf: range.location..<NSMaxRange(range)) }
        }
        #expect(animated.count == 2, "消した絵文字だけは動かさない")
        #expect(tinted.count == 1 && animated.contains(tinted[0]), "足した絵文字は、動かして緑を重ねる")
    }

    /// `image`の中央の画素の、色と不透明さ。
    private func centerPixel(of image: UIImage) throws -> (red: UInt8, green: UInt8, alpha: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cgImage = try #require(image.cgImage)
        context.draw(cgImage, in: CGRect(x: -CGFloat(cgImage.width) / 2 + 0.5, y: -CGFloat(cgImage.height) / 2 + 0.5, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        // 乗算済みのアルファなので、色は不透明さで割り戻す。
        let alpha = pixel[3]
        func unpremultiplied(_ value: UInt8) -> UInt8 { alpha == 0 ? 0 : UInt8(min(255, Int(value) * 255 / Int(alpha))) }
        return (unpremultiplied(pixel[0]), unpremultiplied(pixel[1]), alpha)
    }

    @Test func failedEmojiFallsBackToShortcode() async throws {
        let blobcat = try emoji("blobcat")
        let store = EmojiImageStore.offline
        let loaded = LoadRecorder()
        store.addListener(owner: loaded) { urls in loaded.urls.formUnion(urls) }
        let text = RichText.plain("a:blobcat:", emojis: [blobcat])

        _ = renderer(store).render(text)
        try await waitUntil { !loaded.urls.isEmpty }

        #expect(renderer(store).render(text).string == "a:blobcat:")
    }
}

extension RichTextRendererTests {
    /// カスタム絵文字は、大きさによらず、中心を和文の字面（em枠）の中心に揃える。
    @Test(arguments: [0.5, 1.0, 4.0])
    func customEmojiIsCenteredOnTheEmBox(scale: Double) throws {
        let blobcat = try emoji("blobcat")
        var renderer = renderer(.offline)
        renderer.emojiScale = scale
        let bounds = try #require(attachments(in: renderer.render(.plain("文 :blobcat:", emojis: [blobcat]))).first).bounds

        #expect(abs(bounds.midY - font.pointSize * RichTextRenderer.emojiCenterHeight) < 0.01)
        #expect(abs(bounds.height - font.lineHeight * scale) < 0.01)
    }

    /// 絵文字を大きくした段落は、行の高さを、絵文字が上下に伸びる長さ以上にする。等倍では行の高さを変えない。
    @Test(arguments: [1.0, 3.0])
    func paragraphWithLargeEmojiIsTallEnough(scale: Double) throws {
        let blobcat = try emoji("blobcat")
        var renderer = renderer(.offline)
        renderer.emojiScale = scale
        let text = renderer.render(.plain("文:blobcat:", emojis: [blobcat]))
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let extent = RichTextRenderer.emojiExtent(in: text, range: NSRange(location: 0, length: text.length))

        if scale == 1 {
            #expect(style.minimumLineHeight == 0)
        } else {
            #expect(style.minimumLineHeight >= extent.above + extent.below)
            #expect(extent.below > -font.descender, "大きくした絵文字は、文字の下端より下へも伸びる")
        }
    }
}

@MainActor
private final class LoadRecorder {
    var urls: Set<URL> = []
}
