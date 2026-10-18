import Foundation
import Testing
@testable import SciaCore

/// 投稿に出すリンクカードを、サーバーのカードと、サーバーがカードを付けそうなリンクから選べることを確かめる。
struct LinkCardTests {
    private let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))

    private func status(content: String, media: [MediaAttachment] = [], card: PreviewCard? = nil, quote: Quote? = nil) -> Status {
        Status(
            id: "10",
            createdAt: Date(timeIntervalSince1970: 0),
            account: account,
            content: content,
            spoilerText: "",
            url: nil,
            mediaAttachments: media,
            card: card,
            quote: quote
        )
    }

    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    @Test func prefersServerCard() throws {
        let card = PreviewCard(url: try url("https://news.example/articles/1"), title: "見出し", description: "", type: .link, providerName: "News")
        let target = status(content: #"<p><a href="https://other.example/">other.example</a></p>"#, card: card)

        #expect(LinkCard(status: target) == .card(card))
        #expect(LinkCard(status: target)?.url == card.url)
    }

    @Test func usesFirstLinkWhenServerHasNoCardYet() throws {
        let target = status(content: #"<p><a href="https://first.example/a">first</a> と <a href="https://second.example/b">second</a></p>"#)

        #expect(LinkCard(status: target) == .link(try url("https://first.example/a")))
    }

    /// サーバーと同じく、メンションとハッシュタグのリンクには付けない。
    @Test func skipsMentionsAndHashtags() throws {
        let content = """
        <p><span class="h-card"><a href="https://example.social/@alice" class="u-url mention">@<span>alice</span></a></span> \
        <a href="https://example.social/tags/swift" class="mention hashtag" rel="tag">#<span>swift</span></a> \
        <a href="https://news.example/">news.example</a></p>
        """
        let target = status(content: content)

        #expect(LinkCard(status: target) == .link(try url("https://news.example/")))
    }

    /// サーバーと同じく、`mention`の印がなくても、`u-url`や`h-card`の印のリンクと、メンションの相手のURLへのリンクには付けない。
    @Test func skipsMicroformatAndMentionedAccountLinks() throws {
        let content = #"<p><a href="https://remote.example/users/bob" class="u-url">bob</a> "#
            + #"<span class="h-card"><a href="https://remote.example/@carol" class="h-card">carol</a></span> "#
            + #"<a href="https://remote.example/@dave">dave</a> "#
            + #"<a href="https://news.example/">news.example</a></p>"#
        let target = Status(
            id: "10",
            createdAt: Date(timeIntervalSince1970: 0),
            account: account,
            content: content,
            spoilerText: "",
            url: nil,
            mentions: [Mention(id: "4", username: "dave", url: try url("https://remote.example/@dave"), acct: "dave@remote.example")]
        )

        #expect(LinkCard(status: target) == .link(try url("https://news.example/")))
    }

    /// 他のサーバーの投稿は、Mastodonが本文を整えるときに`rel`を`nofollow noopener`に書き換えるため、`rel="tag"`が残らない。
    /// `class`の`mention`と`hashtag`は残るため、そちらでハッシュタグとメンションを除く。
    @Test func skipsRemoteHashtagsAndMentionsWithoutTagRel() throws {
        let content = #"<p><a href="https://remote.example/tags/swift" class="mention hashtag" rel="nofollow noopener" target="_blank">#<span>swift</span></a> "#
            + #"<a href="https://remote.example/@erin" class="mention" rel="nofollow noopener" target="_blank">@<span>erin</span></a> "#
            + #"<a href="https://news.example/" rel="nofollow noopener" target="_blank">news.example</a></p>"#

        #expect(LinkCard(status: status(content: content)) == .link(try url("https://news.example/")))
    }

    /// カードのサムネイルを、ビューアで開く添付ファイルにする。
    @Test func cardImageBecomesAttachment() throws {
        let card = PreviewCard(
            url: try url("https://news.example/articles/1"),
            title: "見出し",
            description: "",
            type: .link,
            providerName: "News",
            image: try url("https://example.social/cache/preview_cards/images/1.jpeg"),
            width: 400,
            height: 225,
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        )
        let attachment = try #require(card.imageAttachment)

        #expect(attachment.id == "card:https://news.example/articles/1")
        #expect(attachment.type == .image)
        #expect(attachment.url == card.image)
        #expect(attachment.previewUrl == card.image)
        #expect(attachment.meta?.original == MediaAttachment.Size(width: 400, height: 225))
        #expect(attachment.blurhash == card.blurhash)
    }

    /// サムネイルのないカードは開かない。大きさが分からないカードは、大きさを持たせずに開く。
    @Test func cardWithoutImageHasNoAttachment() throws {
        let link = try url("https://news.example/articles/1")
        let noImage = PreviewCard(url: link, title: "", description: "", type: .link, providerName: "")
        let unknownSize = PreviewCard(url: link, title: "", description: "", type: .link, providerName: "", image: try url("https://example.social/1.jpeg"))

        #expect(noImage.imageAttachment == nil)
        #expect(try #require(unknownSize.imageAttachment).meta == nil)
    }

    @Test func noCardWithoutLink() {
        #expect(LinkCard(status: status(content: "<p>リンクのない本文</p>")) == nil)
    }

    /// Mastodonは添付ファイルか引用のある投稿にはカードを付けないため、リンクだけのカードも出さない。
    @Test func noCardForMediaOrQuote() throws {
        let content = #"<p><a href="https://news.example/">news.example</a></p>"#
        let image = MediaAttachment(id: "1", type: .image, url: try url("https://example.social/1.png"), previewUrl: nil)

        #expect(LinkCard(status: status(content: content, media: [image])) == nil)
        #expect(LinkCard(status: status(content: content, quote: Quote(state: "accepted"))) == nil)
    }

    @Test func skipsNonWebLinks() throws {
        let target = status(content: #"<p><a href="mailto:bob@example.social">mail</a> <a href="https://news.example/">news</a></p>"#)

        #expect(LinkCard(status: target) == .link(try url("https://news.example/")))
    }

    @Test func decodesQuote() throws {
        let json = #"{"state":"accepted","quoted_status":null}"#
        let quote = try MastodonDecoder.make().decode(Quote.self, from: Data(json.utf8))

        #expect(quote.state == "accepted")
    }
}
