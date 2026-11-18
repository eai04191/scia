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
        #expect(covers.cover(for: sensitive, filterTitles: [], display: .hidesSensitive) == .sensitive)
        #expect(covers.cover(for: spoiler, filterTitles: [], display: .hidesSensitive) == .sensitive)

        covers.reveal(sensitive)
        #expect(covers.cover(for: sensitive, filterTitles: [], display: .hidesSensitive) == nil)
        #expect(covers.cover(for: spoiler, filterTitles: [], display: .hidesSensitive) == .sensitive)
    }

    @Test func showsPlainStatusUntilHidden() {
        var covers = MediaCovers()
        let plain = status()
        #expect(covers.cover(for: plain, filterTitles: [], display: .hidesSensitive) == nil)

        covers.hide(plain)
        #expect(covers.cover(for: plain, filterTitles: [], display: .hidesSensitive) == .hidden)

        covers.reveal(plain)
        #expect(covers.cover(for: plain, filterTitles: [], display: .hidesSensitive) == nil)
    }

    /// 開いたあとに隠した閲覧注意の投稿は、開く前と同じぼかしに戻す。
    @Test func hidingRevealedSensitiveStatusCoversItAsSensitive() {
        var covers = MediaCovers()
        let sensitive = status(sensitive: true)
        covers.reveal(sensitive)
        covers.hide(sensitive)

        #expect(covers.cover(for: sensitive, filterTitles: [], display: .hidesSensitive) == .sensitive)
    }

    /// 編集履歴では、手元の投稿より新しい版の閲覧注意で既定を決め、使う人の選択は投稿のIDで引く。
    @Test func coverByIDUsesGivenSensitivityAndChoiceOfStatus() {
        var covers = MediaCovers()
        let plain = status(id: "1")
        #expect(covers.cover(forStatusID: plain.id, isSensitive: true, filterTitles: [], display: .hidesSensitive) == .sensitive)
        #expect(covers.cover(forStatusID: plain.id, isSensitive: false, filterTitles: [], display: .hidesSensitive) == nil)

        covers.reveal(plain)
        #expect(covers.cover(forStatusID: plain.id, isSensitive: true, filterTitles: [], display: .hidesSensitive) == nil)

        covers.hide(plain)
        #expect(covers.cover(forStatusID: plain.id, isSensitive: true, filterTitles: [], display: .hidesSensitive) == .sensitive)
        #expect(covers.cover(forStatusID: plain.id, isSensitive: false, filterTitles: [], display: .hidesSensitive) == .hidden)
    }

    /// 隠したかどうかだけを引く。開いた選択と、選んでいない投稿は隠していない扱い。編集履歴で、隠した投稿の過去の版もぼかすために使う。
    @Test func remembersOnlyHidingAsHidden() {
        var covers = MediaCovers()
        let sensitive = status(id: "1", sensitive: true)
        #expect(!covers.isHidden(statusID: sensitive.id))

        covers.hide(sensitive)
        #expect(covers.isHidden(statusID: sensitive.id))

        covers.reveal(sensitive)
        #expect(!covers.isHidden(statusID: sensitive.id))
    }

    @Test func choiceAppliesToBoostsOfSameStatus() {
        var covers = MediaCovers()
        let original = status(id: "10")
        let boost = status(id: "20", reblog: original)

        covers.hide(boost)
        #expect(covers.cover(for: original, filterTitles: [], display: .hidesSensitive) == .hidden)
        #expect(covers.cover(for: boost, filterTitles: [], display: .hidesSensitive) == .hidden)
    }

    @Test func coversLinkCardImageOfSensitiveStatusUntilRevealed() {
        var covers = MediaCovers()
        let sensitive = status(id: "1", sensitive: true, card: card())
        let spoiler = status(id: "2", spoilerText: "ネタバレ", sensitive: true, card: card())
        let plain = status(id: "3", card: card())
        #expect(covers.linkCardImageCover(for: sensitive, display: .hidesSensitive) == .sensitive)
        #expect(covers.linkCardImageCover(for: spoiler, display: .hidesSensitive) == .sensitive)
        #expect(covers.linkCardImageCover(for: plain, display: .hidesSensitive) == nil)

        covers.reveal(sensitive)
        #expect(covers.linkCardImageCover(for: sensitive, display: .hidesSensitive) == nil)
        #expect(covers.linkCardImageCover(for: spoiler, display: .hidesSensitive) == .sensitive)
    }

    /// ぼかす画像がないカードと、カードのない投稿には、ぼかしを出さない。
    @Test func doesNotCoverLinkCardWithoutImage() {
        let covers = MediaCovers()
        #expect(covers.linkCardImageCover(for: status(sensitive: true, card: card(image: nil)), display: .hidesSensitive) == nil)
        #expect(covers.linkCardImageCover(for: status(sensitive: true), display: .hidesSensitive) == nil)
    }

    /// ブーストした行は、ブーストされた投稿のカードと閲覧注意で決め、ぼかしを外したこともそろえる。
    @Test func linkCardImageCoverFollowsBoostedStatus() {
        var covers = MediaCovers()
        let original = status(id: "10", sensitive: true, card: card())
        let boost = status(id: "20", reblog: original)
        #expect(covers.linkCardImageCover(for: boost, display: .hidesSensitive) == .sensitive)

        covers.reveal(original)
        #expect(covers.linkCardImageCover(for: boost, display: .hidesSensitive) == nil)
    }

    /// カードの付いた投稿に、本文を変えずに添付ファイルを足して編集すると、Mastodonはカードを残す（UpdateStatusServiceは本文が変わったときだけカードを作り直す）。
    /// そのとき添付ファイルを「メディアを隠す」でぼかしても、カードの画像はぼかさない。閲覧注意の投稿で外したあとに隠しても、ぼかし直さない。
    @Test func hidingAttachmentsDoesNotCoverLinkCardImage() {
        var covers = MediaCovers()
        let plain = status(id: "1", card: card())
        covers.hide(plain)
        #expect(covers.cover(for: plain, filterTitles: [], display: .hidesSensitive) == .hidden)
        #expect(covers.linkCardImageCover(for: plain, display: .hidesSensitive) == nil)

        let sensitive = status(id: "2", sensitive: true, card: card())
        covers.reveal(sensitive)
        covers.hide(sensitive)
        #expect(covers.cover(for: sensitive, filterTitles: [], display: .hidesSensitive) == .sensitive)
        #expect(covers.linkCardImageCover(for: sensitive, display: .hidesSensitive) == nil)
    }

    /// 「常に表示」では、閲覧注意の添付ファイルとカードの画像をぼかさない。フィルターに一致した投稿と、使う人が隠した投稿はぼかす。
    @Test func showsAllKeepsFilteredAndHiddenCovers() {
        var covers = MediaCovers()
        let sensitive = status(id: "1", sensitive: true, card: card())
        let plain = status(id: "2")
        #expect(covers.cover(for: sensitive, filterTitles: [], display: .showsAll) == nil)
        #expect(covers.linkCardImageCover(for: sensitive, display: .showsAll) == nil)
        #expect(covers.cover(for: plain, filterTitles: ["a"], display: .showsAll) == .filtered(["a"]))

        covers.hide(sensitive)
        covers.hide(plain)
        #expect(covers.cover(for: sensitive, filterTitles: [], display: .showsAll) == .sensitive)
        #expect(covers.cover(for: plain, filterTitles: [], display: .showsAll) == .hidden)
    }

    /// 「常に隠す」では、閲覧注意のない投稿もぼかし、開いた投稿は開いたままにする。カードの画像は、閲覧注意のある投稿だけぼかす。
    @Test func hidesAllCoversPlainStatusesUntilRevealed() {
        var covers = MediaCovers()
        let sensitive = status(id: "1", sensitive: true, card: card())
        let plain = status(id: "2", card: card())
        #expect(covers.cover(for: sensitive, filterTitles: [], display: .hidesAll) == .sensitive)
        #expect(covers.cover(for: plain, filterTitles: [], display: .hidesAll) == .hidden)
        #expect(covers.linkCardImageCover(for: sensitive, display: .hidesAll) == .sensitive)
        #expect(covers.linkCardImageCover(for: plain, display: .hidesAll) == nil)

        covers.reveal(plain)
        #expect(covers.cover(for: plain, filterTitles: [], display: .hidesAll) == nil)
    }
}
