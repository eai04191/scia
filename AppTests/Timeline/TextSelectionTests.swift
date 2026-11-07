import SciaCore
import SciaTesting
import Testing
import TextKit2Label
import UIKit
@testable import Scia

/// 投稿のメニューの「テキストを選択」で、行の本文をその場で選べる状態にするところ。決まりはdocs/menus.mdの「本文の文字を選ぶ」にある。
@Suite(.scratch)
@MainActor
struct TextSelectionTests {
    private let renderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: .offline, language: "ja")

    private func body(_ text: NSAttributedString, statusID: Status.ID = "1") -> PostBodyContent {
        var content = PostBodyContent(text: text, mediaSpacing: 8)
        content.statusID = statusID
        return content
    }

    private func window(showing view: UIView) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.makeKeyAndVisible()
        window.addSubview(view)
        view.frame = CGRect(x: 0, y: 100, width: 328, height: 600)
        return window
    }

    /// カスタム絵文字は`:shortcode:`に、段落の中の改行は改行にしてコピーする。並んだ同じ絵文字も、数を落とさない。
    @Test func copiedTextSpellsOutEmojisAndLineBreaks() throws {
        let emoji = CustomEmoji(
            shortcode: "blob",
            url: try #require(URL(string: "https://example.social/emoji/blob.gif")),
            staticUrl: try #require(URL(string: "https://example.social/emoji/blob.png"))
        )
        let text = NSMutableAttributedString(string: "一行目\u{2028}二行目")
        let emojis = NSMutableAttributedString(attachment: NSTextAttachment())
        emojis.append(NSAttributedString(attachment: NSTextAttachment()))
        emojis.addAttribute(.customEmoji, value: emoji, range: NSRange(location: 0, length: emojis.length))
        text.append(emojis)
        text.append(NSAttributedString(string: "\n次の段落"))

        #expect(text.copiedPlainText == "一行目\n二行目:blob::blob:\n次の段落")
    }

    /// 並べた段落ごとの枠と、その中の行の枠。
    private func lineFrames(of layoutManager: NSTextLayoutManager) -> [[CGRect]] {
        var frames: [[CGRect]] = []
        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            frames.append([fragment.layoutFragmentFrame] + fragment.textLineFragments.map(\.typographicBounds))
            return true
        }
        return frames
    }

    /// 選べるテキストビューは、ラベルと同じ位置に行を並べる。段落の区切りと、段落の中の空行（`<br><br>`）を挟んだ本文で、
    /// ラベルが位置を求めるのに並べ直すTextKit 2の行（ラベルが描く位置と一致することを確かめている）と比べる。
    /// 画素では比べない。文字の縁のアンチエイリアスがラベルとわずかに違うため。
    @Test func selectableTextLaysOutLinesLikeLabel() throws {
        let url = try #require(URL(string: "https://example.com/end"))
        let text = renderer.render(RichText(blocks: [
            .init(inlines: [.text("一段落目は、折り返すくらい長い文章にして、行を何本か並べておく。", [])]),
            .init(inlines: [.text("二段落目", []), .lineBreak, .lineBreak, .text("空行のあと ", []), .link("example.com/end", .url(url), [])]),
        ]))
        let label = LinkLabel()
        label.numberOfLines = 0
        label.attributedText = text
        label.frame = CGRect(origin: .zero, size: label.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)))
        let textView = SelectableTextView(text: try #require(label.textForTextKit))
        textView.frame = CGRect(origin: .zero, size: textView.sizeThatFits(CGSize(width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude)))
        textView.layoutIfNeeded()

        let labelLines = lineFrames(of: label.textLayout(of: try #require(label.attributedText)).layoutManager)
        let textLines = lineFrames(of: try #require(textView.textLayoutManager))

        #expect(labelLines.count == 2)
        #expect(textLines == labelLines)
    }

    /// 大きくした絵文字を重ねて描くラベル（`TextKitLabelLayout.placingOverlaidGlyphs(_:)`）を差し替えても、行の位置は変わらず、
    /// 絵文字を同じ位置に描き、選んだ文字には元の絵文字が渡る。
    @Test func selectableTextKeepsOverlaidEmojiLinesAndText() throws {
        var renderer = renderer
        renderer.textColor = .black
        renderer.emojiStyle = .system
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(.plain("文😀文\n次の行", emojis: []))
        let label = LinkLabel()
        label.drawsWithTextKit = true
        label.numberOfLines = 0
        label.attributedText = text
        label.frame = CGRect(origin: .zero, size: label.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)))
        let textView = SelectableTextView(text: try #require(label.textForTextKit))
        textView.frame = CGRect(origin: .zero, size: textView.sizeThatFits(CGSize(width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude)))
        textView.layoutIfNeeded()

        #expect(lineFrames(of: try #require(textView.textLayoutManager)) == lineFrames(of: label.textLayout(of: try #require(label.attributedText)).layoutManager))
        #expect(textView.overlaidGlyphOrigins == label.overlaidGlyphOrigins)
        #expect(textView.overlaidGlyphOrigins.count == 1)
        let whole = try #require(textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument))
        textView.selectedRange = NSRange(location: 0, length: textView.attributedText.length)
        #expect(textView.text(in: whole) == text.copiedPlainText)
        #expect(textView.attributedText.copiedPlainText == "文😀文\n次の行")
        // 読み上げも、場所取りではなく元の絵文字を読む。
        #expect(textView.accessibilityValue == text.string)
    }

    /// 選べるテキストビューでも、取り消し線は重ねて描く絵文字の上に引く。
    @Test func selectableTextDrawsStrikethroughOverOverlaidEmoji() throws {
        var renderer = renderer
        renderer.textColor = .black
        renderer.emojiStyle = .system
        renderer.unicodeEmojiScale = 2
        let text = renderer.render(RichText(blocks: [.init(inlines: [.text("😀", .strikethrough)])]))
        let label = LinkLabel()
        label.drawsWithTextKit = true
        label.attributedText = text
        label.frame = CGRect(origin: .zero, size: label.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)))
        let textView = SelectableTextView(text: try #require(label.textForTextKit))
        textView.frame = CGRect(origin: .zero, size: textView.sizeThatFits(CGSize(width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude)))
        textView.layoutIfNeeded()
        let origin = try #require(textView.overlaidGlyphOrigins.first)
        // 端末と同じ3倍で描く。行の高さは画素に揃えないので、1倍では1ptの線が2つの画素の行に薄く分かれることがある。
        let scale = 3
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(scale)
        let image = UIGraphicsImageRenderer(bounds: textView.bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(textView.bounds)
            textView.layer.render(in: context.cgContext)
        }
        let cgImage = try #require(image.cgImage)
        let bytes = try #require(CFDataGetBytePtr(cgImage.dataProvider?.data))
        // 取り消し線の黒い画素が、絵文字の幅いっぱいに並ぶ行がある。
        let darkRows = (0..<cgImage.height).filter { y in
            ((Int(origin.x) + 4) * scale..<min(cgImage.width, (Int(origin.x) + 30) * scale)).filter { x in
                let pixel = y * cgImage.bytesPerRow + x * 4
                return Int(bytes[pixel]) + Int(bytes[pixel + 1]) + Int(bytes[pixel + 2]) < 120
            }.count >= 24 * scale
        }
        #expect(!darkRows.isEmpty)
    }

    /// 選べるテキストビューにも、ラベルと同じ位置に引用の縦線を引く。差し替えたときに線が消えないようにするため。
    @Test func selectableTextDrawsQuoteBarsLikeLabel() throws {
        let text = renderer.render(RichText(blocks: [
            .init(inlines: [.text("前の段落", [])]),
            .init(inlines: [.text("引用は、折り返すくらい長い文章にして、線が何行かにわたるようにしておく。", [])], quoteLevel: 1),
            .init(inlines: [.text("入れ子の引用", [])], quoteLevel: 2),
        ]))
        let label = LinkLabel()
        label.numberOfLines = 0
        label.attributedText = text
        label.frame = CGRect(origin: .zero, size: label.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)))
        let textView = SelectableTextView(text: try #require(label.textForTextKit))
        textView.frame = CGRect(origin: .zero, size: textView.sizeThatFits(CGSize(width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude)))
        textView.layoutIfNeeded()

        #expect(label.quoteBarFrames().count == 2)
        #expect(textView.quoteBarFrames == label.quoteBarFrames())
    }

    /// 選び始めると、本文の位置にテキストビューを置き、全体を選ぶ。
    @Test func beginningSelectionCoversTextAndSelectsAll() throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        let text = renderer.render(RichText(blocks: [.init(inlines: [.text("選ぶ本文", [])])]))
        view.apply(body(text))
        view.layoutIfNeeded()

        view.beginTextSelection()
        view.layoutIfNeeded()

        let textView = try #require(view.selectionTextView)
        #expect(abs(textView.frame.minX - view.textFrame.minX) < 0.001)
        #expect(abs(textView.frame.minY - view.textFrame.minY) < 0.001)
        #expect(abs(textView.frame.width - view.textFrame.width) < 0.001)
        // ラベルの高さにそろえると、最後の行の下の行間の分だけ足りず、テキストビューが最後の行を並べない。
        #expect(textView.frame.height >= textView.sizeThatFits(CGSize(width: textView.frame.width, height: CGFloat.greatestFiniteMagnitude)).height)
        #expect(textView.isFirstResponder)
        #expect(textView.selectedRange == NSRange(location: 0, length: text.length))
    }

    /// 指で選択を解いたらやめる。マウスやトラックパッドのクリックで空になったときはやめない。クリックやドラッグは、語や範囲に広げる前に一度選択を空にするため。
    @Test(arguments: [(UITouch.TouchType.direct, true), (.indirectPointer, false)])
    func emptySelectionEndsOnlyByFinger(touchType: UITouch.TouchType, ends: Bool) throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(NSAttributedString(string: "選ぶ本文")))
        view.layoutIfNeeded()
        view.beginTextSelection()
        let textView = try #require(view.selectionTextView)

        textView.lastTouchType = touchType
        textView.selectedRange = NSRange(location: 1, length: 0)

        #expect(view.isSelectingText == !ends)
    }

    /// 同じ投稿の描き直しでは選んだままにし、別の投稿に替わったらやめてラベルに戻す。
    @Test func selectionEndsOnlyWhenRowShowsAnotherStatus() throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        let text = NSAttributedString(string: "選ぶ本文")
        view.apply(body(text))
        view.layoutIfNeeded()
        view.beginTextSelection()

        view.apply(body(text))
        #expect(view.isSelectingText)

        view.apply(body(text, statusID: "2"))
        #expect(!view.isSelectingText)
        #expect(view.selectionTextView == nil)
    }

    /// 同じ投稿の描き直しで本文の属性だけが変わったら（絵文字の画像が届いたなど）、選んだ範囲を保ったまま、テキストビューの中身もそろえる。
    @Test func redrawingSameStatusSyncsTextAndKeepsRange() throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(NSAttributedString(string: "選ぶ本文", attributes: [.foregroundColor: UIColor.label])))
        view.layoutIfNeeded()
        view.beginTextSelection()
        let textView = try #require(view.selectionTextView)
        textView.selectedRange = NSRange(location: 1, length: 2)

        view.apply(body(NSAttributedString(string: "選ぶ本文", attributes: [.foregroundColor: UIColor.systemRed])))

        #expect(view.isSelectingText)
        #expect(textView.selectedRange == NSRange(location: 1, length: 2))
        #expect(textView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .systemRed)
    }

    /// 選んでいる間に本文の幅が変わっても（画面を回したなど）、テキストビューはラベルと同じ位置に行を並べる。
    /// 行より広いカスタム絵文字は並べる幅で縮め、その行の高さも幅で決まる。
    @Test func selectionFollowsTheWidthOfWideEmojiLines() async throws {
        let url = try #require(URL(string: "https://example.social/emoji/wide.png"))
        let emoji = CustomEmoji(shortcode: "wide", url: url, staticUrl: url)
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 160, height: 10)).image { _ in }.pngData())
        let store = EmojiImageStore { _ in png }
        var renderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: store, language: "ja")
        renderer.emojiOnly = EmojiOnlyEnlargement(scale: 2, limit: 10)
        let rich = RichText(blocks: [.init(inlines: [.emoji(emoji)])])
        _ = renderer.render(rich)
        try await waitUntil { store.image(for: url, pixelHeight: EmojiImageStore<UIImage>.pixelHeight) != nil }
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(renderer.render(rich)))
        view.layoutIfNeeded()
        view.beginTextSelection()
        let textView = try #require(view.selectionTextView)

        // 絵文字は656ptの幅なので、どちらの幅でも縮めるが、縮めた高さと行の高さは幅で変わる。
        view.frame.size.width = 200
        view.layoutIfNeeded()

        textView.layoutIfNeeded()
        // 本文のラベルと同じく、TextKit 2で描くラベルを同じ幅に置いて比べる。
        let label = LinkLabel()
        label.drawsWithTextKit = true
        label.numberOfLines = 0
        label.attributedText = renderer.render(rich)
        label.frame = CGRect(x: 0, y: 0, width: textView.bounds.width, height: 1000)
        #expect(textView.bounds.width == 200)
        #expect(lineFrames(of: try #require(textView.textLayoutManager)) == lineFrames(of: label.textLayout(of: try #require(label.attributedText)).layoutManager))
        #expect(view.isSelectingText)
    }

    /// 編集メニューの調べる、翻訳、ウェブを検索、共有が読む、選んだ範囲の文字では、カスタム絵文字を`:shortcode:`にする。
    /// 選んだ範囲のほかは、位置の計算がずれないよう、文字数をそろえたまま返す。
    @Test func selectedTextSpellsOutEmojis() throws {
        let emoji = CustomEmoji(
            shortcode: "blob",
            url: try #require(URL(string: "https://example.social/emoji/blob.gif")),
            staticUrl: try #require(URL(string: "https://example.social/emoji/blob.png"))
        )
        let text = NSMutableAttributedString(string: "前")
        let attachment = NSMutableAttributedString(attachment: NSTextAttachment())
        attachment.addAttribute(.customEmoji, value: emoji, range: NSRange(location: 0, length: attachment.length))
        text.append(attachment)
        text.append(NSAttributedString(string: "後"))
        let textView = SelectableTextView(text: text)
        textView.selectedRange = NSRange(location: 0, length: text.length)
        let start = textView.beginningOfDocument
        let whole = try #require(textView.textRange(from: start, to: textView.endOfDocument))
        let afterEmoji = try #require(textView.position(from: start, offset: 2))
        let firstTwo = try #require(textView.textRange(from: start, to: afterEmoji))

        #expect(textView.text(in: whole) == "前:blob:後")
        #expect(textView.text(in: firstTwo) == "前\u{FFFC}")
    }

    /// タイムラインの行と同じく、幅を決めて測った高さ。
    private func fittingHeight(of view: UIView) -> CGFloat {
        view.systemLayoutSizeFitting(CGSize(width: 328, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
    }

    /// 選んでいる間は、サーバーが縮めて見せるURLを元のURLで出し、選んだ文字をそのまま渡す。書式で分かれたURLも1つのURLに戻す。
    /// 伸びた分だけ本文が高くなり、やめたら縮めた表示と高さに戻す。
    @Test func selectionShowsShortenedURLsWhole() throws {
        let html = #"<p>見て <a href="https://example.com/users/someone/status/2109995948407476369?s=46"><span class="invisible">https://</span><span class="ellipsis">example.com/users/someone/stat</span><span class="invisible">us/2109995948407476369?s=46</span></a> と <a href="https://example.com/a/very/long/path/to/some/page"><span class="invisible">https://</span><span class="ellipsis">example.com/<b>a/very/long/path/</b></span><span class="invisible">to/some/page</span></a></p>"#
        let whole = "見て https://example.com/users/someone/status/2109995948407476369?s=46 と https://example.com/a/very/long/path/to/some/page"
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(renderer.render(RichText.html(html, emojis: []))))
        view.layoutIfNeeded()
        let shortHeight = fittingHeight(of: view)

        view.beginTextSelection()
        let textView = try #require(view.selectionTextView)
        #expect(textView.attributedText.copiedPlainText == whole)
        // 選んだ文字が、そのまま共有などに渡る。
        let urlStart = (textView.attributedText.string as NSString).range(of: "example.com/users").location
        textView.selectedRange = NSRange(location: urlStart, length: 11)
        let range = try #require(textView.selectedTextRange)
        #expect(textView.text(in: range) == "example.com")
        #expect(fittingHeight(of: view) > shortHeight)

        view.endTextSelection()
        #expect(view.expandedText == nil)
        #expect(fittingHeight(of: view) == shortHeight)
    }

    /// 選んでいる間に同じ投稿を描き直しても、元のURLで出したまま選び続ける。
    @Test func redrawingWhileSelectingKeepsURLsWhole() throws {
        let html = #"<p><a href="https://example.com/a/very/long/path/to/some/page"><span class="invisible">https://</span><span class="ellipsis">example.com/a/very/long/path/</span><span class="invisible">to/some/page</span></a></p>"#
        let text = renderer.render(RichText.html(html, emojis: []))
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(text))
        view.layoutIfNeeded()
        view.beginTextSelection()

        view.apply(body(text))

        #expect(view.isSelectingText)
        #expect(view.selectionTextView?.attributedText.copiedPlainText == "https://example.com/a/very/long/path/to/some/page")
    }

    /// 縮めて見せる文字は同じでも、隠した部分が編集されて元のURLが変わったら、選んだ範囲がずれるのでやめる。
    @Test func redrawingWithEditedHiddenURLPartEndsSelection() throws {
        func html(_ tail: String) -> String {
            #"<p><a href="https://example.com/a/very/long/path/\#(tail)"><span class="invisible">https://</span><span class="ellipsis">example.com/a/very/long/path/</span><span class="invisible">\#(tail)</span></a> 後ろ</p>"#
        }
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        view.apply(body(renderer.render(RichText.html(html("to/some/page"), emojis: []))))
        view.layoutIfNeeded()
        view.beginTextSelection()

        view.apply(body(renderer.render(RichText.html(html("to/another/longer/page"), emojis: []))))

        #expect(!view.isSelectingText)
        #expect(view.expandedText == nil)
    }

    /// 押下を受ける高さ（差し替えたラベルの高さ）より下では押下を受けず、文字に合わせて伸ばした最後の行の下の行間が、下の部品へのタップを奪わない。
    @Test func spaceBelowTouchableHeightDoesNotTakeTouches() {
        let textView = SelectableTextView(text: NSAttributedString(string: "選ぶ本文"))
        textView.frame = CGRect(x: 0, y: 0, width: 300, height: 40)
        textView.touchableHeight = { 20 }

        #expect(textView.point(inside: CGPoint(x: 10, y: 10), with: nil))
        #expect(!textView.point(inside: CGPoint(x: 10, y: 30), with: nil))
    }

    /// 行数で切っている本文と、注意書きで折りたたんでいる本文は選べない。
    @Test func truncatedOrCollapsedTextCannotBeSelected() throws {
        let view = PostBodyView(mediaImages: .offline, avatarImages: .offline)
        let window = try window(showing: view)
        defer { window.isHidden = true }
        var truncated = body(NSAttributedString(string: "切った本文"))
        truncated.maximumLines = 2
        view.apply(truncated)
        #expect(!view.canSelectText)

        var collapsed = body(NSAttributedString(string: "隠した本文"))
        collapsed.spoiler = PostBodyContent.Spoiler(text: NSAttributedString(string: "注意"), isCollapsed: true, padding: 8, bodySpacing: 8, buttonFont: .preferredFont(forTextStyle: .footnote), buttonSpacing: 4, cornerRadius: 8)
        view.apply(collapsed)
        #expect(!view.canSelectText)

        view.apply(body(NSAttributedString(string: "表示している本文")))
        #expect(view.canSelectText)
    }
}
