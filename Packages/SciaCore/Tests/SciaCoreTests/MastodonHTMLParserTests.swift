import Foundation
import Testing
@testable import SciaCore

struct MastodonHTMLParserTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    private func emoji(_ shortcode: String) throws -> CustomEmoji {
        CustomEmoji(
            shortcode: shortcode,
            url: try url("https://example.social/emoji/\(shortcode).gif"),
            staticUrl: try url("https://example.social/emoji/\(shortcode).png")
        )
    }

    private func parse(_ html: String, mentions: [Mention] = [], tags: [SciaCore.Tag] = [], emojis: [CustomEmoji] = []) -> RichText {
        MastodonHTMLParser(mentions: mentions, tags: tags, emojis: emojis).parse(html)
    }

    @Test func paragraphsAndLineBreaks() {
        let text = parse("<p>一行目<br />二行目</p><p>次の段落</p>")

        #expect(text.blocks == [
            RichText.Block(inlines: [.text("一行目", []), .lineBreak, .text("二行目", [])]),
            RichText.Block(inlines: [.text("次の段落", [])]),
        ])
    }

    @Test func decodesEntities() {
        #expect(parse("<p>&lt;tag&gt; &amp; &quot;q&quot; &#39;s&#39; &#x1F600; &unknown; a&b</p>").plainText
            == "<tag> & \"q\" 's' 😀 &unknown; a&b")
    }

    @Test func shortensURLLikeMastodonWeb() throws {
        let html = """
        <p><a href="https://example.com/users/someone/status/2109995948407476369?s=46" target="_blank" rel="nofollow noopener" translate="no"><span class="invisible">https://</span><span class="ellipsis">example.com/users/someone/stat</span><span class="invisible">us/2109995948407476369?s=46</span></a><br />え、な、なに？</p>
        """

        let text = parse(html)

        #expect(text.blocks.first?.inlines == [
            .link("example.com/users/someone/stat…", .url(try url("https://example.com/users/someone/status/2109995948407476369?s=46")), []),
            .lineBreak,
            .text("え、な、なに？", []),
        ])
    }

    @Test func resolvesMentionFromStatusMentions() throws {
        let mention = Mention(id: "2", username: "bob", url: try url("https://remote.example/@bob"), acct: "bob@remote.example")
        let html = #"<p><span class="h-card" translate="no"><a href="https://remote.example/@bob" class="u-url mention">@<span>bob</span></a></span> こんにちは</p>"#

        let text = parse(html, mentions: [mention])

        #expect(text.blocks.first?.inlines == [
            .link("@bob", .mention(acct: "bob@remote.example", url: try url("https://remote.example/@bob")), []),
            .text(" こんにちは", []),
        ])
    }

    @Test func mentionNotInListFallsBackToLinkText() throws {
        let html = #"<p><a href="https://remote.example/@carol" class="u-url mention">@<span>carol</span></a></p>"#

        #expect(parse(html).blocks.first?.inlines == [
            .link("@carol", .mention(acct: "carol", url: try url("https://remote.example/@carol")), []),
        ])
    }

    @Test func hashtag() throws {
        let html = #"<p><a href="https://example.social/tags/scia" class="mention hashtag" rel="tag">#<span>scia</span></a></p>"#

        #expect(parse(html).blocks.first?.inlines == [
            .link("#scia", .hashtag(name: "scia", url: try url("https://example.social/tags/scia")), []),
        ])
    }

    /// Misskeyの投稿のハッシュタグは`class`がなく、`rel`も`nofollow noopener`に書き換わって届く。
    /// リンクの文字列が投稿のタグの名前に`#`を付けたものなら、ハッシュタグとして読む。
    @Test func misskeyHashtagWithoutMarkersMatchesStatusTags() throws {
        let html = #"<p><a href="https://misskey.example/tags/bot" rel="nofollow noopener" target="_blank">#bot</a> <a href="https://misskey.example/tags/other" rel="nofollow noopener" target="_blank">#other</a></p>"#

        #expect(parse(html, tags: [SciaCore.Tag(name: "bot", url: nil)]).blocks.first?.inlines == [
            .link("#bot", .hashtag(name: "bot", url: try url("https://misskey.example/tags/bot")), []),
            .text(" ", []),
            .link("#other", .url(try url("https://misskey.example/tags/other")), []),
        ])
    }

    @Test func replacesCustomEmojiShortcodes() throws {
        let blobcat = try emoji("blobcat")
        let text = parse("<p>えあい:blobcat::unknown::blobcat:です</p>", emojis: [blobcat])

        #expect(text.blocks.first?.inlines == [
            .text("えあい", []),
            .emoji(blobcat),
            .text(":unknown:", []),
            .emoji(blobcat),
            .text("です", []),
        ])
    }

    @Test func plainTextReplacesEmojiWithoutParsingHTML() throws {
        let verified = try emoji("verified")
        let text = RichText.plain("えあい:verified: <b>", emojis: [verified])

        #expect(text.blocks.first?.inlines == [.text("えあい", []), .emoji(verified), .text(" <b>", [])])
    }

    @Test func inlineStyles() {
        let text = parse("<p><strong>太字</strong><em>斜体</em><del>取り消し</del><u>下線</u><code>x</code><b><i>両方</i></b></p>")

        #expect(text.blocks.first?.inlines == [
            .text("太字", .bold),
            .text("斜体", .italic),
            .text("取り消し", .strikethrough),
            .text("下線", .underline),
            .text("x", .code),
            .text("両方", [.bold, .italic]),
        ])
    }

    @Test func blockquoteAndCodeBlock() {
        let text = parse("<blockquote><p>引用</p></blockquote><pre><code>let a = 1\n  b</code></pre><p>後</p>")

        #expect(text.blocks == [
            RichText.Block(inlines: [.text("引用", [])], quoteLevel: 1),
            RichText.Block(inlines: [.text("let a = 1\n  b", [])], isCode: true),
            RichText.Block(inlines: [.text("後", [])]),
        ])
    }

    @Test func lists() {
        let text = parse(#"<ul><li>りんご</li><li>みかん</li></ul><ol start="3"><li>三</li><li>四</li></ol>"#)

        #expect(text.blocks == [
            RichText.Block(inlines: [.text("りんご", [])], listMarker: "• ", listLevel: 1),
            RichText.Block(inlines: [.text("みかん", [])], listMarker: "• ", listLevel: 1),
            RichText.Block(inlines: [.text("三", [])], listMarker: "3. ", listLevel: 1),
            RichText.Block(inlines: [.text("四", [])], listMarker: "4. ", listLevel: 1),
        ])
    }

    @Test func collapsesWhitespaceOutsidePre() {
        #expect(parse("<p>\n  a \n\n b  </p>").plainText == "a b")
    }

    @Test func unknownTagsKeepText() {
        #expect(parse("<p><h1>見出し</h1><marquee>流れる</marquee></p>").plainText == "見出し流れる")
    }

    @Test func textWithoutParagraph() {
        #expect(parse("段落なし<br>改行").blocks == [
            RichText.Block(inlines: [.text("段落なし", []), .lineBreak, .text("改行", [])]),
        ])
    }

    @Test func unsupportedLinkBecomesText() {
        #expect(parse(#"<p><a href="not a url">リンク</a></p>"#).blocks.first?.inlines == [.text("リンク", [])])
    }

    @Test func statusUsesItsMentionsAndEmojis() throws {
        let blobcat = try emoji("blobcat")
        let status = Status(
            id: "1",
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: try url("https://example.social/a.png")),
            content: "<p>:blobcat:</p>",
            spoilerText: "",
            url: nil,
            emojis: [blobcat]
        )

        #expect(RichText.status(status).blocks.first?.inlines == [.emoji(blobcat)])
    }

    @Test func keepsIdeographicAndOtherNonASCIISpaces() {
        #expect(parse("<p>あ\u{3000}\u{3000}い\u{2003}う</p>").plainText == "あ\u{3000}\u{3000}い\u{2003}う")
    }

    @Test func listItemContainingParagraphKeepsMarker() {
        let text = parse("<ul><li><p>本文</p></li><li>次</li></ul>")

        #expect(text.blocks == [
            RichText.Block(inlines: [.text("本文", [])], listMarker: "• ", listLevel: 1),
            RichText.Block(inlines: [.text("次", [])], listMarker: "• ", listLevel: 1),
        ])
    }

    @Test func keepsInlineStylesInsideLink() throws {
        let link = RichText.LinkDestination.url(try url("https://example.com"))

        #expect(parse(#"<p><a href="https://example.com"><strong>重要</strong> 通常</a></p>"#).blocks.first?.inlines == [
            .link("重要", link, .bold),
            .link(" 通常", link, []),
        ])
    }
}
