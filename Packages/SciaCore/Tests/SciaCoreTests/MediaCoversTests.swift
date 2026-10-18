import Foundation
import Testing
@testable import SciaCore

struct MediaCoversTests {
    private let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))

    private func status(id: String = "10", spoilerText: String = "", sensitive: Bool = false, reblog: Status? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: account, content: "<p>本文</p>", spoilerText: spoilerText, url: nil, sensitive: sensitive, reblog: reblog)
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
}
