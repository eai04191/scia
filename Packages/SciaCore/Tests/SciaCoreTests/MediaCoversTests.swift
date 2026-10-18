import Foundation
import Testing
@testable import SciaCore

struct MediaCoversTests {
    private let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))

    private func status(id: String = "10", spoilerText: String = "", sensitive: Bool = false, card: PreviewCard? = nil, reblog: Status? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: account, content: "<p>本文</p>", spoilerText: spoilerText, url: nil, sensitive: sensitive, card: card, reblog: reblog)
    }

    private func card(image: URL? = URL(string: "https://example.social/card.png")) -> PreviewCard? {
        URL(string: "https://news.example/a").map {
            PreviewCard(url: $0, title: "見出し", description: "", type: .link, providerName: "News", image: image, blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        }
    }

    @Test func coversSensitiveAndSpoilerStatusesUntilRevealed() {
        var covers = MediaCovers()
        let sensitive = status(id: "1", sensitive: true)
        let spoiler = status(id: "2", spoilerText: "ネタバレ")
        #expect(covers.cover(for: sensitive) == .sensitive)
        #expect(covers.cover(for: spoiler) == .sensitive)

        covers.reveal(sensitive)
        #expect(covers.cover(for: sensitive) == nil)
        #expect(covers.cover(for: spoiler) == .sensitive)
    }

    @Test func showsPlainStatusUntilHidden() {
        var covers = MediaCovers()
        let plain = status()
        #expect(covers.cover(for: plain) == nil)

        covers.hide(plain)
        #expect(covers.cover(for: plain) == .hidden)

        covers.reveal(plain)
        #expect(covers.cover(for: plain) == nil)
    }

    /// 開いたあとに隠した閲覧注意の投稿は、開く前と同じ覆いに戻す。
    @Test func hidingRevealedSensitiveStatusCoversItAsSensitive() {
        var covers = MediaCovers()
        let sensitive = status(sensitive: true)
        covers.reveal(sensitive)
        covers.hide(sensitive)

        #expect(covers.cover(for: sensitive) == .sensitive)
    }

    @Test func choiceAppliesToBoostsOfSameStatus() {
        var covers = MediaCovers()
        let original = status(id: "10")
        let boost = status(id: "20", reblog: original)

        covers.hide(boost)
        #expect(covers.cover(for: original) == .hidden)
        #expect(covers.cover(for: boost) == .hidden)
    }

    @Test func coversLinkCardImageOfSensitiveStatusUntilRevealed() {
        var covers = MediaCovers()
        let sensitive = status(id: "1", sensitive: true, card: card())
        let spoiler = status(id: "2", spoilerText: "ネタバレ", sensitive: true, card: card())
        let plain = status(id: "3", card: card())
        #expect(covers.linkCardImageCover(for: sensitive) == .sensitive)
        #expect(covers.linkCardImageCover(for: spoiler) == .sensitive)
        #expect(covers.linkCardImageCover(for: plain) == nil)

        covers.reveal(sensitive)
        #expect(covers.linkCardImageCover(for: sensitive) == nil)
        #expect(covers.linkCardImageCover(for: spoiler) == .sensitive)
    }

    /// 覆う画像がないカードと、カードのない投稿には、覆いを出さない。
    @Test func doesNotCoverLinkCardWithoutImage() {
        let covers = MediaCovers()
        #expect(covers.linkCardImageCover(for: status(sensitive: true, card: card(image: nil))) == nil)
        #expect(covers.linkCardImageCover(for: status(sensitive: true)) == nil)
    }

    /// ブーストした行は、ブーストされた投稿のカードと閲覧注意で決め、覆いを外したこともそろえる。
    @Test func linkCardImageCoverFollowsBoostedStatus() {
        var covers = MediaCovers()
        let original = status(id: "10", sensitive: true, card: card())
        let boost = status(id: "20", reblog: original)
        #expect(covers.linkCardImageCover(for: boost) == .sensitive)

        covers.reveal(original)
        #expect(covers.linkCardImageCover(for: boost) == nil)
    }

    /// カードの付いた投稿に、本文を変えずに添付ファイルを足して編集すると、Mastodonはカードを残す（UpdateStatusServiceは本文が変わったときだけカードを作り直す）。
    /// そのとき添付ファイルを「メディアを隠す」で覆っても、カードの画像は覆わない。閲覧注意の投稿で外したあとに隠しても、覆い直さない。
    @Test func hidingAttachmentsDoesNotCoverLinkCardImage() {
        var covers = MediaCovers()
        let plain = status(id: "1", card: card())
        covers.hide(plain)
        #expect(covers.cover(for: plain) == .hidden)
        #expect(covers.linkCardImageCover(for: plain) == nil)

        let sensitive = status(id: "2", sensitive: true, card: card())
        covers.reveal(sensitive)
        covers.hide(sensitive)
        #expect(covers.cover(for: sensitive) == .sensitive)
        #expect(covers.linkCardImageCover(for: sensitive) == nil)
    }
}
