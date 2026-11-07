import CoreText
import Foundation
import SciaCore
import SciaTesting
import Synchronization
import Testing
import TextKit2Label
import UIKit
@testable import Scia

@MainActor
struct RichTextRendererTests {
    private let font = UIFont.preferredFont(forTextStyle: .body)

    private func emoji(_ shortcode: String) throws -> CustomEmoji {
        let url = try #require(URL(string: "https://example.social/emoji/\(shortcode).png"))
        return CustomEmoji(shortcode: shortcode, url: url, staticUrl: url)
    }

    private func renderer(_ store: EmojiImageStore<UIImage>, paragraphSpacing: CGFloat = 0) -> RichTextRenderer {
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
        let store = EmojiImageStore<UIImage>.offline
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
        #expect(abs(bounds.height - EmojiFont.glyphHeight(of: font) * scale) < 0.01)
    }

    /// 絵文字は、割合の大きさの書体で描き、中心を字面の中心に揃える。文字の形で描く指定の付いた文字、本文の書体が持つ「©」、キーキャップにならない数字は変えない。
    @Test func unicodeEmojiIsScaledAndCentered() throws {
        var renderer = renderer(.offline)
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(.plain("文😀1️⃣❤☺\u{FE0E}©1#", emojis: []))
        let string = text.string as NSString
        func attributes(of cluster: String) -> [NSAttributedString.Key: Any] {
            text.attributes(at: string.range(of: cluster).location, effectiveRange: nil)
        }

        // 「❤」は既定では文字で描く指定の文字だが、本文の書体が持たないため絵文字の書体で描かれる。
        for cluster in ["😀", "1️⃣", "❤"] {
            let font = try #require(attributes(of: cluster)[.font] as? UIFont)
            let offset = try #require(attributes(of: cluster)[.baselineOffset] as? CGFloat)
            // 絵の高さが、文字の大きさのまま描いたときの2倍になる大きさにする。
            #expect(abs(EmojiFont.glyphHeight(of: font) - EmojiFont.glyphHeight(of: self.font) * 2) < 0.01, "\(cluster)")
            // 描く絵の中心を、ずらしたあとに文字の字面の中心へ揃える。
            #expect(abs(EmojiFont.glyphBounds(of: font).midY + offset - self.font.pointSize * RichTextRenderer.emojiCenterHeight) < 0.01, "\(cluster)")
        }
        for cluster in ["文", "☺\u{FE0E}", "©", "1#"] {
            #expect((attributes(of: cluster)[.font] as? UIFont)?.pointSize == font.pointSize, "\(cluster)")
            #expect(attributes(of: cluster)[.scaledUnicodeEmoji] == nil, "\(cluster)")
        }
    }

    /// 絵文字を大きくした段落は、行の高さを、絵文字の上端から文字の下端（descent）までにする。下へ伸びる分は、ラベルが行の下に足す。等倍では行の高さを変えない。
    @Test(arguments: [1.0, 3.0])
    func paragraphWithLargeEmojiIsTallEnough(scale: Double) throws {
        var renderer = renderer(.offline)
        renderer.unicodeEmojiScale = scale
        let text = renderer.render(.plain("文😀", emojis: []))
        let style = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let extent = RichTextRenderer.emojiExtent(in: text, range: NSRange(location: 0, length: text.length))

        if scale == 1 {
            #expect(style.minimumLineHeight == 0)
        } else {
            #expect(style.minimumLineHeight == ceil(max(font.ascender, extent.above) - font.descender))
            #expect(extent.below > -font.descender, "大きくした絵文字は、文字の下端より下へも伸びる")
        }
    }

    /// 段落の中の改行で区切った行のうち、大きくした絵文字のある行だけを高くする。ほかの行は、絵文字のない段落の行と同じ間隔で並ぶ。
    @Test func lineBreakAfterLargeEmojiKeepsFollowingLinesAtTextHeight() throws {
        let html = "<p>😀文<br>文<br>文</p><p>文</p>"
        let parser = MastodonHTMLParser(mentions: [], tags: [], emojis: [])
        var large = renderer(.offline, paragraphSpacing: 12)
        large.lineSpacing = 4
        large.unicodeEmojiScale = 2
        var plain = large
        plain.unicodeEmojiScale = 1

        let baselines = { (text: NSAttributedString) -> [CGFloat] in
            let style = TextKitLabelLayout.Style(font: font, textColor: .label, lineBreakMode: .byWordWrapping, direction: .leftToRight, displayScale: 1)
            let layout = TextKitLabelLayout.layout(of: TextKitLabelLayout.filled(text, style: style), width: 400, maximumLines: 0, style: style)
            var result: [CGFloat] = []
            layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
                for line in fragment.textLineFragments {
                    result.append(fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
                }
                return true
            }
            return result
        }
        let largeLines = baselines(large.render(parser.parse(html)))
        let plainLines = baselines(plain.render(parser.parse(html)))

        try #require(largeLines.count == 4 && plainLines.count == 4)
        #expect(largeLines[1] - largeLines[0] > plainLines[1] - plainLines[0], "絵文字の行は高くなる")
        #expect(abs((largeLines[2] - largeLines[1]) - (plainLines[2] - plainLines[1])) < 0.5, "絵文字のない行は高くならない")
        #expect(abs((largeLines[3] - largeLines[2]) - (plainLines[3] - plainLines[2])) < 0.5, "段落の間隔は変わらない")
    }

    /// 改行で区切らずに折り返した行でも、TextKit 2で描くラベルでは、大きくした絵文字のある行だけを高くする。
    @Test func wrappedLinesBeforeLargeEmojiKeepTextHeight() throws {
        let html = "<p>" + String(repeating: "文", count: 30) + "😀</p>"
        let parser = MastodonHTMLParser(mentions: [], tags: [], emojis: [])
        var large = renderer(.offline)
        large.lineSpacing = 4
        large.unicodeEmojiScale = 2
        var plain = large
        plain.unicodeEmojiScale = 1

        let baselines = { (text: NSAttributedString) -> [CGFloat] in
            let style = TextKitLabelLayout.Style(font: font, textColor: .label, lineBreakMode: .byWordWrapping, direction: .leftToRight, displayScale: 1, overlaysGlyphs: true)
            let layout = TextKitLabelLayout.layout(of: TextKitLabelLayout.filled(text, style: style), width: font.pointSize * 12, maximumLines: 0, style: style)
            var result: [CGFloat] = []
            layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
                for line in fragment.textLineFragments {
                    result.append(fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
                }
                return true
            }
            return result
        }
        let largeLines = baselines(large.render(parser.parse(html)))
        let plainLines = baselines(plain.render(parser.parse(html)))

        try #require(largeLines.count == 3 && plainLines.count == 3)
        #expect(abs((largeLines[1] - largeLines[0]) - (plainLines[1] - plainLines[0])) < 0.5, "絵文字のない行は高くならない")
        #expect(largeLines[2] - largeLines[1] > plainLines[2] - plainLines[1], "絵文字の行は高くなる")
    }

    /// 並べた結果の最初と最後の行の範囲は、段落をまたいでも、渡した文字列での位置になる。
    /// 本文の上下の余白は、この範囲の絵文字で測る。
    @Test func metricsReportFirstAndLastLineRanges() throws {
        var renderer = renderer(.offline)
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(MastodonHTMLParser(mentions: [], tags: [], emojis: []).parse("<p>" + String(repeating: "文", count: 30) + "😀</p><p>後の段落😀" + String(repeating: "文", count: 30) + "</p>"))
        let style = TextKitLabelLayout.Style(font: font, textColor: .label, lineBreakMode: .byWordWrapping, direction: .leftToRight, displayScale: 1, overlaysGlyphs: true)
        let layout = TextKitLabelLayout.layout(of: TextKitLabelLayout.filled(text, style: style), width: font.pointSize * 12, maximumLines: 0, style: style)
        let metrics = try #require(TextKitLabelLayout.metrics(of: layout, displayScale: 1))
        let string = text.string as NSString

        #expect(metrics.firstLineRange.location == 0)
        #expect(!string.substring(with: metrics.firstLineRange).contains("😀"))
        #expect(NSMaxRange(metrics.lastLineRange) == string.length)
        #expect(!string.substring(with: metrics.lastLineRange).contains("😀"))
        #expect(PostBodyView.textTopInset(of: text, firstLine: metrics.firstLineRange) == font.pointSize * PostBodyView.emBoxAscent)
        #expect(PostBodyView.textTopInset(of: text) > font.pointSize * PostBodyView.emBoxAscent, "段落で測ると絵文字の上端になる")
        #expect(PostBodyView.textBottomInset(of: text, lastLine: metrics.lastLineRange) == font.pointSize * PostBodyView.emBoxDescent)
    }

    /// 同じ行の中で「…」に置き換わった絵文字は描かない。
    /// 色のある画素は、色の絵文字と同じ行にある文字の縁にも出るので、行ではなく画素の数で、絵文字を描いた量と比べる。
    @Test func emojiReplacedByEllipsisInTheSameLineIsNotDrawn() throws {
        var renderer = renderer(.offline)
        renderer.textColor = .black
        renderer.emojiStyle = .system
        renderer.unicodeEmojiScale = 2
        let truncated = try coloredPixelCount(of: renderer.render(.plain("文😀文", emojis: [])), width: 40, numberOfLines: 1)
        let visible = try coloredPixelCount(of: renderer.render(.plain("文😀", emojis: [])), width: 200, numberOfLines: 1)

        #expect(truncated * 10 < visible, "\(truncated) \(visible)")
    }

    /// 取り消し線は、重ねて描く絵文字の上に引く。
    @Test func strikethroughIsDrawnOverOverlaidEmoji() throws {
        var renderer = renderer(.offline)
        renderer.textColor = .black
        renderer.emojiStyle = .system
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(RichText(blocks: [.init(inlines: [.text("😀", .strikethrough)])]))
        let label = EmojiLabel()
        label.drawsWithTextKit = true
        label.attributedText = text
        label.frame = CGRect(origin: .zero, size: label.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude)))
        let layout = label.textLayout(of: try #require(label.attributedText))
        let origin = try #require(label.overlaidGlyphOrigins.first)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: label.bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(label.bounds)
            label.drawText(in: label.bounds)
        }
        _ = layout
        // 取り消し線は文字の書体の字面の中ほどに引かれる。そこに、線の黒い画素が絵文字の幅いっぱいに並ぶ行がある。
        let cgImage = try #require(image.cgImage)
        let bytes = try #require(CFDataGetBytePtr(cgImage.dataProvider?.data))
        let width = Int(label.bounds.width)
        let darkRows = (0..<cgImage.height).filter { y in
            let dark = (Int(origin.x) + 4..<min(width, Int(origin.x) + 30)).filter { x in
                let pixel = y * cgImage.bytesPerRow + x * 4
                return Int(bytes[pixel]) + Int(bytes[pixel + 1]) + Int(bytes[pixel + 2]) < 120
            }
            return dark.count >= 24
        }
        #expect(!darkRows.isEmpty)
    }

    /// TextKit 2で描くときは、大きくしたUnicodeの絵文字の行を、同じ大きさのカスタム絵文字の行と同じ高さにする。
    /// 絵文字の書体のascenderとdescenderとleadingは絵の上下に余白を持ち、下げて描いた分もdescentに足されるため、そのまま並べると行が高くなる。
    @Test func overlaidUnicodeEmojiLineIsAsTallAsCustomEmojiLine() throws {
        var unicode = renderer(.offline)
        unicode.unicodeEmojiScale = 2
        var custom = renderer(.offline)
        custom.emojiScale = 2
        let parser = MastodonHTMLParser(mentions: [], tags: [], emojis: [try emoji("a")])
        let baselines = { (text: NSAttributedString, overlays: Bool) -> [CGFloat] in
            var style = TextKitLabelLayout.Style(font: font, textColor: .label, lineBreakMode: .byWordWrapping, direction: .leftToRight, displayScale: 1)
            style.overlaysGlyphs = overlays
            let layout = TextKitLabelLayout.layout(of: TextKitLabelLayout.filled(text, style: style), width: 400, maximumLines: 0, style: style)
            var result: [CGFloat] = []
            layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
                for line in fragment.textLineFragments {
                    result.append(fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y)
                }
                return true
            }
            return result
        }
        let overlaid = baselines(unicode.render(parser.parse("<p>文<br>😀文<br>文</p>")), true)
        let plain = baselines(unicode.render(parser.parse("<p>文<br>😀文<br>文</p>")), false)
        let customLines = baselines(custom.render(parser.parse("<p>文<br>:a:文<br>文</p>")), true)

        try #require(overlaid.count == 3 && customLines.count == 3 && plain.count == 3)
        for index in 0..<3 {
            #expect(abs(overlaid[index] - customLines[index]) < 0.5, "\(overlaid) \(customLines)")
        }
        #expect(plain[2] > overlaid[2] + 10, "UILabelで描くときは、書体のまま並べる")
    }

    /// 場所取りに置き換えても、改行できる位置は変わらない。絵文字のすぐ後ろで折り返せる。
    @Test func overlaidEmojiKeepsLineBreakOpportunities() throws {
        var renderer = renderer(.offline)
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(.plain("文😀文", emojis: []))
        let firstLineLength = { (overlays: Bool, width: CGFloat) -> Int in
            var style = TextKitLabelLayout.Style(font: font, textColor: .label, lineBreakMode: .byWordWrapping, direction: .leftToRight, displayScale: 1)
            style.overlaysGlyphs = overlays
            let layout = TextKitLabelLayout.layout(of: TextKitLabelLayout.filled(text, style: style), width: width, maximumLines: 0, style: style)
            var length = 0
            layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
                length = fragment.textLineFragments.first?.characterRange.length ?? 0
                return false
            }
            return length
        }
        // 「文😀」までは入り、最後の「文」は入らない幅。
        let width = (text.attributedSubstring(from: NSRange(location: 0, length: 3)).size().width).rounded(.up) + 2
        let plain = firstLineLength(false, width)
        #expect(plain == 3, "書体のまま並べると「文😀」で折り返す")
        #expect(firstLineLength(true, width) == plain)
    }

    /// 場所取りに置き換えても、ラベルが返す文字列とコピーには、置き換える前の文字が渡る。
    @Test func overlaidEmojiKeepsTheTextForCopyAndAccessibility() throws {
        var renderer = renderer(.offline)
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(.plain("文👨‍👩‍👧😀", emojis: []))
        let label = EmojiLabel()
        label.drawsWithTextKit = true
        label.attributedText = text
        label.frame = CGRect(x: 0, y: 0, width: 400, height: 100)

        #expect(label.attributedText?.string == text.string)
        #expect(label.attributedText?.copiedPlainText == "文👨‍👩‍👧😀")
        let placed = TextKitLabelLayout.placingOverlaidGlyphs(TextKitLabelLayout.filled(text, style: label.textKitStyle))
        #expect(placed.length == text.length, "文字の位置が変わらない")
        // 家族の絵文字は1つの絵文字として、その全体が1つの枠になる。
        let family = (text.string as NSString).range(of: "👨‍👩‍👧")
        let layout = label.textLayout(of: try #require(label.attributedText))
        let frame = try #require(label.characterFrame(at: family.location + 2, in: text, contentStorage: layout.contentStorage, layoutManager: layout.layoutManager))
        #expect(frame.width > font.pointSize)
    }

    /// 改行で区切った行を段落に分けても、行は分ける前の段落の書く向きで並ぶ。
    @Test func splitLinesKeepTheParagraphWritingDirection() throws {
        var renderer = renderer(.offline)
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(MastodonHTMLParser(mentions: [], tags: [], emojis: []).parse("<p>😀English<br>العربية</p>"))
        let style = TextKitLabelLayout.Style(font: font, textColor: .label, lineBreakMode: .byWordWrapping, direction: .leftToRight, displayScale: 1)
        let layout = TextKitLabelLayout.layout(of: TextKitLabelLayout.filled(text, style: style), width: 400, maximumLines: 0, style: style)
        let arabic = (text.string as NSString).range(of: "العربية")
        let location = try #require(layout.contentStorage.location(layout.layoutManager.documentRange.location, offsetBy: arabic.location))

        #expect(text.string.contains("\n"), "行の高さが違うので段落に分ける")
        #expect(layout.layoutManager.baseWritingDirection(at: location) == .leftToRight)
    }

    /// 末尾が空の行で終わる段落を分けても、次の段落との間隔は残る。
    @Test func splitParagraphEndingWithEmptyLineKeepsParagraphSpacing() throws {
        var renderer = renderer(.offline, paragraphSpacing: 12)
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(MastodonHTMLParser(mentions: [], tags: [], emojis: []).parse("<pre><code>😀\na\n</code></pre><p>後</p>"))
        let next = (text.string as NSString).range(of: "後").location
        let style = try #require(text.attribute(.paragraphStyle, at: next - 2, effectiveRange: nil) as? NSParagraphStyle)

        #expect(style.paragraphSpacing == 12)
    }
}

extension RichTextRendererTests {
    /// TextKit 2で描くラベルに描いた、色のある画素の数。
    private func coloredPixelCount(of text: NSAttributedString, width: CGFloat, numberOfLines: Int) throws -> Int {
        let label = EmojiLabel()
        label.drawsWithTextKit = true
        label.numberOfLines = numberOfLines
        label.attributedText = text
        var size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        size.width = min(size.width, width)
        label.frame = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            label.drawText(in: label.bounds)
        }
        let cgImage = try #require(image.cgImage)
        let bytes = try #require(CFDataGetBytePtr(cgImage.dataProvider?.data))
        return (0..<cgImage.height).reduce(0) { count, y in
            count + (0..<cgImage.width).filter { x in
                let pixel = y * cgImage.bytesPerRow + x * 4
                let channels = [bytes[pixel], bytes[pixel + 1], bytes[pixel + 2]]
                return Int(channels.max() ?? 0) - Int(channels.min() ?? 0) > 64
            }.count
        }
    }

    /// ラベルに描いた色のある画素の、上端と下端の行。文字は黒で描くので、色のある画素は絵文字だけになる。
    /// - Parameter drawsWithTextKit: TextKit 2で描くラベルで描く。
    private func coloredRows(of text: NSAttributedString, width: CGFloat = 400, drawsWithTextKit: Bool = false, numberOfLines: Int = 0) throws -> ClosedRange<Int>? {
        let label = EmojiLabel()
        label.drawsWithTextKit = drawsWithTextKit
        label.numberOfLines = numberOfLines
        label.attributedText = text
        var size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        size.width = min(size.width, width)
        label.frame = CGRect(origin: .zero, size: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: size.height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: size.height))
            label.drawText(in: label.bounds)
        }
        let cgImage = try #require(image.cgImage)
        let bytes = try #require(CFDataGetBytePtr(cgImage.dataProvider?.data))
        let rows = (0..<cgImage.height).filter { y in
            (0..<cgImage.width).contains { x in
                let pixel = y * cgImage.bytesPerRow + x * 4
                let channels = [bytes[pixel], bytes[pixel + 1], bytes[pixel + 2]]
                return Int(channels.max() ?? 0) - Int(channels.min() ?? 0) > 64
            }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first...last
    }

    /// 絵文字だけの段落と、大きさの違う絵文字が隣り合う段落でも、余白は文字の書体から測り、絵文字は1つずつ測る。
    @Test func emojiOnlyAndMixedSizeEmojisAreMeasuredFromTheTextFont() throws {
        var renderer = renderer(.offline)
        renderer.unicodeEmojiScale = 4
        let emojiOnly = renderer.render(.plain("😀", emojis: []))
        #expect(RichTextRenderer.textFont(in: emojiOnly, range: NSRange(location: 0, length: emojiOnly.length))?.pointSize == font.pointSize)

        // 書体の大きさが違う2つの絵文字を隣に並べ、大きいほうまで測る。
        let mixed = NSMutableAttributedString(attributedString: renderer.render(.plain("😀😀", emojis: [])))
        let second = NSRange(location: 2, length: 2)
        let larger = font.withSize(font.pointSize * 8)
        mixed.addAttributes([.font: larger, .baselineOffset: RichTextRenderer.emojiCenterHeight * (font.pointSize - larger.pointSize)], range: second)
        let extent = RichTextRenderer.emojiExtent(in: mixed, range: NSRange(location: 0, length: mixed.length))
        #expect(extent.below >= -(EmojiFont.glyphBounds(of: larger).minY + RichTextRenderer.emojiCenterHeight * (font.pointSize - larger.pointSize)) - 0.01)
    }

    /// 大きくした絵文字の上下の範囲は、大きさを揃える基準の絵文字（🟥）の枠ではなく、その絵文字の字形で測る。
    /// 「⚕️」や「♀️」は🟥より下へ伸びるため、基準の枠で測ると、下の部品とのあいだを狭く見積もって重なる。
    @Test(arguments: ["⚕️", "♀️"])
    func extentCoversEachEmojisOwnGlyph(cluster: String) throws {
        var renderer = renderer(.offline)
        // twemojiの「⚕️」と「♀️」は、🟥と下端が同じなので、Appleの絵文字で確かめる。
        renderer.emojiStyle = .system
        renderer.unicodeEmojiScale = 4
        let text = renderer.render(.plain("文\(cluster)", emojis: []))
        let range = (text.string as NSString).range(of: cluster)
        let font = try #require(text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
        let offset = try #require(text.attribute(.baselineOffset, at: range.location, effectiveRange: nil) as? CGFloat)
        let glyph = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(NSAttributedString(string: cluster, attributes: [.font: font])), .useGlyphPathBounds)
        let extent = RichTextRenderer.emojiExtent(in: text, range: NSRange(location: 0, length: text.length))

        #expect(glyph.minY < EmojiFont.glyphBounds(of: font).minY, "基準の絵文字より下へ伸びる絵文字で確かめる")
        #expect(extent.below >= -(glyph.minY + offset) - 0.01)
        #expect(extent.above >= glyph.maxY + offset - 0.01)
    }

    /// 下げて描く絵文字が先頭にあると幅のない文字を前に置くが、コピーする文字には含めない。
    @Test func leadingEmojiGuardIsNotCopied() {
        var renderer = renderer(.offline)
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(.plain("😀文", emojis: []))

        #expect(text.string.hasPrefix(RichTextRenderer.leadingEmojiGuard))
        #expect(text.copiedPlainText == "😀文")
    }

    /// 大きくした絵文字は、行の先頭に置いても末尾に置いても、ラベルの中で欠けずに同じ高さで描く。
    @Test(arguments: [2.0, 4.0], [false, true])
    func largeUnicodeEmojiIsNotClippedAtLineStart(scale: Double, drawsWithTextKit: Bool) throws {
        var renderer = renderer(.offline)
        renderer.textColor = .black
        renderer.emojiStyle = .system
        renderer.unicodeEmojiScale = scale
        let leading = try #require(try coloredRows(of: renderer.render(.plain("😀文", emojis: [])), drawsWithTextKit: drawsWithTextKit))
        let trailing = try #require(try coloredRows(of: renderer.render(.plain("文😀", emojis: [])), drawsWithTextKit: drawsWithTextKit))

        #expect(abs(leading.count - trailing.count) <= 1, "TextKit=\(drawsWithTextKit) 先頭=\(leading) 末尾=\(trailing)")
    }

    /// TextKit 2で描くラベルは、大きくした絵文字を、UILabelで描くときと同じ大きさで、行の上端から描く。行数で切られて並ばなかった絵文字は描かない。
    @Test func textKitLabelDrawsOverlaidEmojiAtTheLineTopAndSkipsTruncatedOnes() throws {
        var renderer = renderer(.offline)
        renderer.textColor = .black
        renderer.emojiStyle = .system
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(.plain("文😀", emojis: []))
        let overlaid = try #require(try coloredRows(of: text, drawsWithTextKit: true))
        let drawnByLabel = try #require(try coloredRows(of: text))

        #expect(abs(overlaid.count - drawnByLabel.count) <= 1, "\(overlaid) \(drawnByLabel)")
        // 書体のまま並べると、絵の上に書体の余白の分が空く。
        #expect(overlaid.lowerBound < drawnByLabel.lowerBound - 8, "\(overlaid) \(drawnByLabel)")

        // 色のある画素は、色の絵文字と同じ行にある文字の縁にも出るので、絵文字の高さより低いことで、絵文字を描いていないと確かめる。
        let truncated = try coloredRows(of: renderer.render(.plain(String(repeating: "文", count: 40) + "😀", emojis: [])), width: 200, drawsWithTextKit: true, numberOfLines: 1)
        #expect((truncated?.count ?? 0) < overlaid.count / 2, "\(String(describing: truncated))")
    }
}

@MainActor
private final class LoadRecorder {
    var urls: Set<URL> = []
}

extension RichTextRendererTests {
    private func mentionReply(_ rest: String) -> RichText {
        let url = URL(string: "https://example.social/@bob")
        return RichText(blocks: [.init(inlines: (url.map { [.link("@bob", .mention(acct: "bob", url: $0), [])] } ?? []) + [.text(rest, [])])])
    }

    /// 絵文字だけの本文は、カスタム絵文字と普通の絵文字の割合に同じ倍率を掛けて描く。先頭のメンションは普通の大きさのまま描く。
    @Test func emojiOnlyBodyMultipliesBothEmojiScales() throws {
        let blobcat = try emoji("blobcat")
        var renderer = renderer(.offline)
        renderer.emojiScale = 1.5
        renderer.unicodeEmojiScale = 0.8
        renderer.emojiOnly = EmojiOnlyEnlargement(scale: 2, limit: 10)
        var text = mentionReply(" 😀")
        text.blocks[0].inlines.append(.emoji(blobcat))
        let rendered = renderer.render(text)
        let string = rendered.string as NSString

        let emojiFont = try #require(rendered.attribute(.font, at: string.range(of: "😀").location, effectiveRange: nil) as? UIFont)
        #expect(abs(EmojiFont.glyphHeight(of: emojiFont) - EmojiFont.glyphHeight(of: font) * 1.6) < 0.01)
        let bounds = try #require(attachments(in: rendered).first).bounds
        #expect(abs(bounds.height - EmojiFont.glyphHeight(of: font) * 3) < 0.01)
        let mentionFont = try #require(rendered.attribute(.font, at: string.range(of: "@bob").location, effectiveRange: nil) as? UIFont)
        #expect(mentionFont.pointSize == font.pointSize)
        #expect(rendered.attribute(.emojiOnlyBody, at: 0, effectiveRange: nil) != nil)
    }

    /// 上限より多い絵文字は大きくしない。絵文字だけの本文であることは残す。
    @Test(arguments: [(2, true), (1, false), (0, false)])
    func emojiOnlyBodyIsEnlargedUpToTheLimit(limit: Int, enlarged: Bool) throws {
        var renderer = renderer(.offline)
        renderer.emojiOnly = EmojiOnlyEnlargement(scale: 2, limit: limit)
        let rendered = renderer.render(.plain("😀🎉", emojis: []))

        let emojiFont = try #require(rendered.attribute(.font, at: (rendered.string as NSString).range(of: "😀").location, effectiveRange: nil) as? UIFont)
        #expect(abs(EmojiFont.glyphHeight(of: emojiFont) - EmojiFont.glyphHeight(of: font) * (enlarged ? 2 : 1)) < 0.01)
        #expect(rendered.attribute(.emojiOnlyBody, at: 0, effectiveRange: nil) != nil)
    }

    /// 文字のある本文は、絵文字だけの本文として扱わない。
    @Test func mixedBodyIsNotEnlarged() throws {
        var renderer = renderer(.offline)
        renderer.emojiOnly = EmojiOnlyEnlargement(scale: 2, limit: 10)
        let rendered = renderer.render(.plain("いいね😀", emojis: []))

        #expect(rendered.attribute(.scaledUnicodeEmoji, at: (rendered.string as NSString).range(of: "😀").location, effectiveRange: nil) == nil)
        #expect(rendered.attribute(.emojiOnlyBody, at: 0, effectiveRange: nil) == nil)
    }

    /// 絵文字かどうかは、描く書体で決める。等幅の書体が持たず、絵文字の絵で描かれる文字は、コード書式でも絵文字と数える。
    @Test func emojiOnlyBodyJudgesCodeWithTheMonospacedFont() throws {
        var renderer = renderer(.offline)
        renderer.emojiOnly = EmojiOnlyEnlargement(scale: 2, limit: 10)
        let rendered = renderer.render(RichText(blocks: [.init(inlines: [.text("✈", .code), .text("😀", [])])]))

        #expect(rendered.attribute(.emojiOnlyBody, at: 0, effectiveRange: nil) != nil)
    }
}
