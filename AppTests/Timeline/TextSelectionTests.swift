import SciaCore
import SciaTesting
import Testing
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
