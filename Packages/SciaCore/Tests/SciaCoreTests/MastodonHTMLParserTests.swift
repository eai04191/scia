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

    /// `;`のあとに結合する文字が続くと、`;`とつながって1文字になる。それでも文字参照として戻す。
    @Test func decodesEntityFollowedByCombiningMark() {
        #expect(parse("<p>&gt;\u{0338} &amp;\u{FE0F}\u{20E3}</p>").plainText == ">\u{0338} &\u{FE0F}\u{20E3}")
    }

    @Test func shortensURLLikeMastodonWeb() throws {
        let html = """
        <p><a href="https://example.com/users/someone/status/2109995948407476369?s=46" target="_blank" rel="nofollow noopener" translate="no"><span class="invisible">https://</span><span class="ellipsis">example.com/users/someone/stat</span><span class="invisible">us/2109995948407476369?s=46</span></a><br />え、な、なに？</p>
        """

        let text = parse(html)

        #expect(text.blocks.first?.inlines == [
            .link(
                "example.com/users/someone/stat…",
                .url(try url("https://example.com/users/someone/status/2109995948407476369?s=46")),
                [],
                copied: RichText.CopiedLinkText(text: "https://example.com/users/someone/status/2109995948407476369?s=46", index: 0)
            ),
            .lineBreak,
            .text("え、な、なに？", []),
        ])
    }

    /// 書式で分かれたリンクは、どのインラインにも同じ元の文字を持たせ、つないだときは1回だけ入れる。隣り合う同じ文字の別のリンクは、それぞれ入れる。
    @Test func splitShortenedLinkCopiesWholeTextOnce() throws {
        let link = #"<a href="https://example.com/a/very/long/path/to/some/page"><span class="invisible">https://</span><span class="ellipsis">example.com/<b>a/very/long/path/</b></span><span class="invisible">to/some/page</span></a>"#
        let destination = RichText.LinkDestination.url(try url("https://example.com/a/very/long/path/to/some/page"))
        let whole = "https://example.com/a/very/long/path/to/some/page"
        let copied = RichText.CopiedLinkText(text: whole, index: 0)

        let text = parse("<p>\(link)\(link)</p>")

        #expect(text.blocks.first?.inlines.prefix(3) == [
            .link("example.com/", destination, [], copied: copied),
            .link("a/very/long/path/", destination, .bold, copied: copied),
            .link("…", destination, [], copied: copied),
        ])
        #expect(text.copiedText == whole + whole)
    }

    /// プロフィールの補足情報は幅に余裕があるので、サーバーが30字で縮めた後ろの部分も出す。先頭のスキームは省いたまま出し、コピーには入れる。
    @Test func profileFieldShowsWholeShortenedURL() throws {
        let html = """
        <a href="https://github.com/eai04191/scia/blob/main/.claude/skills/codex-proof-review/SKILL.md" target="_blank" rel="nofollow noopener me" translate="no"><span class="invisible">https://</span><span class="ellipsis">github.com/eai04191/scia/blob/</span><span class="invisible">main/.claude/skills/codex-proof-review/SKILL.md</span></a>
        """

        let text = RichText.profileField(html, emojis: [])

        #expect(text.blocks.first?.inlines == [
            .link(
                "github.com/eai04191/scia/blob/main/.claude/skills/codex-proof-review/SKILL.md",
                .url(try url("https://github.com/eai04191/scia/blob/main/.claude/skills/codex-proof-review/SKILL.md")),
                [],
                copied: RichText.CopiedLinkText(text: "https://github.com/eai04191/scia/blob/main/.claude/skills/codex-proof-review/SKILL.md", index: 0)
            ),
        ])
    }

    /// プロフィールの補足情報のコピーと翻訳にも、縮めたURLは元の文字で渡す。
    @Test func profileFieldCopiesShortenedURLWithScheme() {
        let value = #"<a href="https://example.com/a/very/long/path/to/some/page"><span class="invisible">https://</span><span class="ellipsis">example.com/a/very/long/path/</span><span class="invisible">to/some/page</span></a>"#
        let account = Account(id: "1", username: "a", acct: "a", displayName: "A", avatar: nil, fields: [Account.Field(name: "web", value: value)])

        #expect(account.profileText(.field(0))?.text == "https://example.com/a/very/long/path/to/some/page")
    }

    /// サーバーが知らない相手のハンドルは文字のまま届く。補足情報と自己紹介では、押してプロフィールを開けるようにする。
    @Test func profileTextLinksPlainHandle() {
        let expected: [RichText.Inline] = [
            .text("本垢は ", []),
            .link("@alice@example.social", .handle(acct: "alice@example.social"), []),
            .text(" です", []),
        ]
        #expect(RichText.profileField("本垢は @alice@example.social です", emojis: []).blocks.first?.inlines == expected)
        #expect(RichText.profileNote("<p>本垢は @alice@example.social です</p>", emojis: []).blocks.first?.inlines == expected)
    }

    @Test(arguments: [
        ("@alice@example.social", "alice@example.social", "@alice@example.social"),
        ("@a.b-c_d@sub.example.co.jp。", "a.b-c_d@sub.example.co.jp", "@a.b-c_d@sub.example.co.jp"),
        ("サブ@alice@example.social", "alice@example.social", "@alice@example.social"),
        ("@alice@xn--vusz0j.artです", "alice@xn--vusz0j.art", "@alice@xn--vusz0j.art"),
    ])
    func findsPlainHandle(text: String, acct: String, shown: String) {
        let links = RichText.profileField(text, emojis: []).blocks.flatMap(\.inlines).filter { if case .link = $0 { true } else { false } }
        #expect(links == [.link(shown, .handle(acct: acct), [])])
    }

    /// どのサーバーの人か決まらない語、メールアドレス、URLの一部は、リンクにしない。
    @Test(arguments: ["@alice", "alice@example.social", "mail.@alice@example.social", "a@alice@example.social", "https://example.social/@alice@example.social", "@alice@localhost", "@alice@example.social@other", "@alice@sub.example.social@other", "@alice@social.example.みんな"])
    func ignoresWhatIsNotHandle(text: String) {
        #expect(RichText.profileField(text, emojis: []).blocks.first?.inlines == [.text(text, [])])
    }

    /// 書式で分かれて続くハンドルの片方だけをリンクにすると、別のサーバーを指す。
    @Test(arguments: ["<p><strong>@alice@example.social</strong>.other.org</p>", "<p>@alice@sub.example.<em>social</em></p>"])
    func keepsHandleSplitByStyle(html: String) {
        let links = RichText.profileNote(html, emojis: []).blocks.flatMap(\.inlines).filter { if case .link = $0 { true } else { false } }
        #expect(links.isEmpty)
    }

    /// 1つの書式に収まるハンドルは、書式を保ってリンクにする。
    @Test func linksHandleInsideStyle() {
        #expect(RichText.profileNote("<p>本垢 <strong>@alice@example.social</strong> です</p>", emojis: []).blocks.first?.inlines == [
            .text("本垢 ", []),
            .link("@alice@example.social", .handle(acct: "alice@example.social"), .bold),
            .text(" です", []),
        ])
    }

    /// サーバーが付けたリンクの中の文字と、コードの中の文字は読まない。
    @Test func keepsLinkAndCodeAsTheyAre() throws {
        let linked = #"<a href="https://example.social/@alice" class="u-url mention">@alice@example.social</a>"#
        #expect(RichText.profileField(linked, emojis: []).blocks.first?.inlines == [
            .link("@alice@example.social", .mention(acct: "alice@example.social", url: try url("https://example.social/@alice")), []),
        ])
        #expect(RichText.profileNote("<p><code>@alice@example.social</code></p>", emojis: []).blocks.first?.inlines == [.text("@alice@example.social", .code)])
        #expect(RichText.profileNote("<pre>@alice@example.social</pre>", emojis: []).blocks.first?.inlines == [.text("@alice@example.social", [])])
    }

    /// 投稿の本文は、Mastodonが投稿するときに相手を探してメンションにするので、文字のまま残ったものは読まない。
    @Test func statusKeepsPlainHandle() {
        #expect(parse("<p>@alice@example.social</p>").blocks.first?.inlines == [.text("@alice@example.social", [])])
    }

    /// 文字のままのハンドルにしたリンクも、コピーと翻訳には書かれた文字を渡す。
    @Test func profileTextCopiesPlainHandleAsWritten() {
        let account = Account(id: "1", username: "a", acct: "a", displayName: "A", avatar: nil, note: "<p>@alice@example.social</p>", fields: [Account.Field(name: "本垢", value: "@alice@example.social")])
        #expect(account.profileText(.field(0))?.text == "@alice@example.social")
        #expect(account.profileText(.note)?.text == "@alice@example.social")
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

    /// 名前が`U+FE0F U+20E3`で始まると、`#`とつながってキーキャップの絵文字`#️⃣`の1文字になる。
    /// 文字ではなくUnicodeのスカラー値で`#`を外し、残りを名前にする。
    @Test func hashtagStartingWithKeycapCombiningMarks() throws {
        let name = "\u{FE0F}\u{20E3}🅰️0️⃣"
        let html = #"<p><a href="https://example.social/tags/x" class="mention hashtag" rel="tag">#<span>"# + name + "</span></a></p>"

        #expect(parse(html).blocks.first?.inlines == [
            .link("#" + name, .hashtag(name: name, url: try url("https://example.social/tags/x")), []),
        ])
    }

    @Test func misskeyHashtagStartingWithKeycapCombiningMarksMatchesStatusTags() throws {
        let name = "\u{FE0F}\u{20E3}🅰️0️⃣"
        let html = #"<p><a href="https://misskey.example/tags/x" rel="nofollow noopener" target="_blank">#"# + name + "</a></p>"

        #expect(parse(html, tags: [SciaCore.Tag(name: "🅰0", url: nil)]).blocks.first?.inlines == [
            .link("#" + name, .hashtag(name: name, url: try url("https://misskey.example/tags/x")), []),
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

    /// 番号の上限や下限を越える`<ol>`は、Mastodonのサニタイズを通って届く。越えた先は端の番号のままにし、落ちない。
    @Test func listNumbersSaturateAtIntegerBounds() {
        let text = parse(#"<ol start="9223372036854775807"><li>一</li><li>二</li></ol><ol reversed start="-9223372036854775808"><li>三</li><li>四</li></ol><ol><li value="9223372036854775807">五</li><li>六</li></ol>"#)

        #expect(text.blocks.map(\.listMarker) == [
            "9223372036854775807. ", "9223372036854775807. ",
            "-9223372036854775808. ", "-9223372036854775808. ",
            "9223372036854775807. ", "9223372036854775807. ",
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
