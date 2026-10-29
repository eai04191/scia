import Foundation
import Testing
@testable import SciaCore

struct EmojiOnlyBodyTests {
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

    private func mention() throws -> Mention {
        Mention(id: "2", username: "bob", url: try url("https://remote.example/@bob"), acct: "bob@remote.example")
    }

    /// 描く側の書体に頼らない、絵文字の見分け方。絵文字の絵で描く指定のある文字だけを絵文字とみなす。
    private func count(_ html: String, mentions: [Mention] = [], emojis: [CustomEmoji] = []) -> Int? {
        MastodonHTMLParser(mentions: mentions, tags: [], emojis: emojis).parse(html).emojiOnlyCount { cluster, _, _ in
            cluster.unicodeScalars.first?.properties.isEmojiPresentation == true || cluster.unicodeScalars.contains("\u{FE0F}")
        }
    }

    @Test func countsUnicodeAndCustomEmojisAlike() throws {
        #expect(count("<p>👍:blobcat:🎉</p>", emojis: [try emoji("blobcat")]) == 3)
    }

    /// 肌の色やZWJでつないだ絵文字、国旗は、1つの絵として1個と数える。
    @Test func countsComposedEmojiAsOne() {
        #expect(count("<p>👍🏽👨‍👩‍👧🇯🇵</p>") == 3)
    }

    @Test func ignoresWhitespaceAndLineBreaks() {
        #expect(count("<p> 👍  🎉<br />✨</p><p>🌱</p>") == 4)
    }

    @Test func textMakesItNotEmojiOnly() {
        #expect(count("<p>👍 いいね</p>") == nil)
    }

    @Test func emptyBodyIsNotEmojiOnly() {
        #expect(count("") == nil)
        #expect(count("<p> </p>") == nil)
    }

    /// 返信の先頭に自動で入るメンションは除いて数える。
    @Test func skipsLeadingMentions() throws {
        let html = #"<p><span class="h-card"><a href="https://remote.example/@bob" class="u-url mention">@<span>bob</span></a></span> 👍</p>"#
        #expect(count(html, mentions: [try mention()]) == 1)
    }

    @Test func mentionAloneIsNotEmojiOnly() throws {
        let html = #"<p><span class="h-card"><a href="https://remote.example/@bob" class="u-url mention">@<span>bob</span></a></span></p>"#
        #expect(count(html, mentions: [try mention()]) == nil)
    }

    @Test func mentionAfterEmojiMakesItNotEmojiOnly() throws {
        let html = #"<p>👍 <span class="h-card"><a href="https://remote.example/@bob" class="u-url mention">@<span>bob</span></a></span></p>"#
        #expect(count(html, mentions: [try mention()]) == nil)
    }

    @Test func hashtagOrLinkMakesItNotEmojiOnly() {
        #expect(count(#"<p>🎉 <a href="https://example.social/tags/tag" class="mention hashtag" rel="tag">#<span>tag</span></a></p>"#) == nil)
        #expect(count(#"<p>🎉 <a href="https://example.com/">example.com</a></p>"#) == nil)
    }

    /// 文字で描く指定の付いた記号は、描く側が絵文字とみなさなければ、絵文字だけとはみなさない。
    @Test func followsTheGivenEmojiTest() {
        #expect(count("<p>©</p>") == nil)
    }

    /// リスト項目は番号や記号を描くので、絵文字だけとはみなさない。
    @Test func listIsNotEmojiOnly() {
        #expect(count("<ol><li>👍</li></ol>") == nil)
        #expect(count("<ul><li>👍</li><li>🎉</li></ul>") == nil)
        #expect(count("<p>🎉</p><ul><li>👍</li></ul>") == nil)
    }

    /// 絵文字かどうかは、その文字を描く書式と段落で決める。
    @Test func passesStyleAndBlockOfEachCharacter() {
        var seen: [(String, RichText.Style, Bool)] = []
        _ = MastodonHTMLParser(mentions: [], tags: [], emojis: []).parse("<p><code>✈</code>😀</p><pre>🎉</pre>").emojiOnlyCount { cluster, style, block in
            seen.append((cluster, style, block.isCode))
            return true
        }
        #expect(seen.map(\.0) == ["✈", "😀", "🎉"])
        #expect(seen.map(\.1) == [.code, [], []])
        #expect(seen.map(\.2) == [false, false, true])
    }
}
