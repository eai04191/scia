import Foundation
import Testing
@testable import SciaCore

/// 通知で再掲する投稿の本文の、段落と改行を詰めた形。決まりはdocs/notification-display.mdの「再掲する投稿の本文」にある。
struct RichTextJoiningLinesTests {
    private func joined(_ html: String) -> RichText {
        MastodonHTMLParser(mentions: [], tags: [], emojis: []).parse(html).joiningLines()
    }

    /// 段落と改行は、空白を1つ置いて1つの段落につなぐ。
    @Test func joinsParagraphsAndLineBreaksWithSpace() {
        let text = joined("<p>一行目<br />二行目</p><p>次の段落</p>")
        #expect(text.blocks.count == 1)
        #expect(text.plainText == "一行目 二行目 次の段落")
    }

    /// 境目の前後がもともと空白なら、空白を足さない。
    @Test(arguments: [("前 ", "後"), ("前", " 後"), ("前\u{3000}", "後")])
    func doesNotDoubleSpaces(before: String, after: String) {
        let text = RichText(blocks: [RichText.Block(inlines: [.text(before, [])]), RichText.Block(inlines: [.text(after, [])])]).joiningLines()
        #expect(text.plainText == before + after)
    }

    /// リンクと絵文字は、つないだあとも同じ部品のまま残る。
    @Test func keepsLinks() throws {
        let text = joined(#"<p>前</p><p><a href="https://example.com/">example.com</a></p>"#)
        let url = try #require(URL(string: "https://example.com/"))
        #expect(text.blocks.first?.inlines == [.text("前", []), .text(" ", []), .link("example.com", .url(url), [])])
    }

    /// リスト項目の記号は項目の頭に文字として残し、字下げはしない。
    @Test func keepsListMarkersWithoutIndent() {
        let text = joined("<p>買うもの</p><ul><li>りんご</li><li>みかん</li></ul>")
        #expect(text.plainText == "買うもの • りんご • みかん")
        #expect(text.blocks.first?.listLevel == 0 && text.blocks.first?.quoteLevel == 0)
    }

    /// 引用は字下げせずにつなぐ。
    @Test func joinsQuotesWithoutIndent() {
        let text = joined("<p>前</p><blockquote><p>引用</p></blockquote>")
        #expect(text.plainText == "前 引用")
        #expect(text.blocks.first?.quoteLevel == 0)
    }

    /// コードブロックの改行は空白にし、等幅の書体のまま出す。
    @Test func joinsCodeBlockLinesKeepingMonospace() {
        let text = joined("<p>前</p><pre><code>let a = 1\nlet b = 2</code></pre>")
        #expect(text.plainText == "前 let a = 1 let b = 2")
        #expect(text.blocks.first?.isCode == false)
        let codeStyles = text.blocks.first?.inlines.compactMap { inline -> RichText.Style? in
            guard case .text(let string, let style) = inline, string.contains("let") else { return nil }
            return style
        }
        #expect(codeStyles?.isEmpty == false && codeStyles?.allSatisfy { $0.contains(.code) } == true)
    }

    /// リンクの中の改行も空白にし、リンクは行き先を保った1つの部品のまま残す。
    @Test func joinsBreakInsideLink() throws {
        let text = joined(#"<p><a href="https://example.com/">一つ目<br>二つ目</a></p><p>三つ目</p>"#)
        let url = try #require(URL(string: "https://example.com/"))
        #expect(text.blocks.first?.inlines == [.link("一つ目 二つ目", .url(url), []), .text(" ", []), .text("三つ目", [])])
    }

    /// コードブロックの中のリンクも、等幅の書体のまま出す。
    @Test func keepsMonospaceForLinkInCodeBlock() throws {
        let text = joined(#"<pre><code>curl <a href="https://example.com/">https://example.com/</a></code></pre>"#)
        let styles = text.blocks.first?.inlines.compactMap { inline -> RichText.Style? in
            if case .link(_, _, let style) = inline { style } else { nil }
        }
        #expect(styles?.count == 1 && styles?.allSatisfy { $0.contains(.code) } == true)
    }

    /// リンクの端がもともと空白なら、境目に空白を足さない。
    @Test(arguments: [
        #"<p><a href="https://example.com/">前 </a><br>後</p>"#,
        #"<p>前<br><a href="https://example.com/"> 後</a></p>"#,
    ])
    func doesNotDoubleSpacesAtLinkEdges(html: String) {
        #expect(joined(html).plainText == "前 後")
    }

    @Test func keepsEmptyTextEmpty() {
        #expect(RichText(blocks: []).joiningLines() == RichText(blocks: []))
    }
}
