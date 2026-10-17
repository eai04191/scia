import Foundation
import Testing
@testable import SciaCore

struct SpoilerExpansionTests {
    private let account = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png"))

    private func status(id: String = "10", spoilerText: String = "ネタバレ", reblog: Status? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: account, content: "<p>本文</p>", spoilerText: spoilerText, url: nil, reblog: reblog)
    }

    @Test func collapsesStatusWithSpoilerByDefault() {
        #expect(SpoilerExpansion().isCollapsed(status()))
    }

    @Test func neverCollapsesStatusWithoutSpoiler() {
        var expansion = SpoilerExpansion()
        let plain = status(spoilerText: "")
        expansion.toggle(plain)

        #expect(!expansion.isCollapsed(plain))
    }

    @Test func followsServerPreferenceUntilToggled() {
        var expansion = SpoilerExpansion(expandsByDefault: true)
        let target = status()
        #expect(!expansion.isCollapsed(target))

        expansion.toggle(target)
        #expect(expansion.isCollapsed(target))
    }

    @Test func toggleOpensAndClosesAgain() {
        var expansion = SpoilerExpansion()
        let target = status()

        expansion.toggle(target)
        #expect(!expansion.isCollapsed(target))
        expansion.toggle(target)
        #expect(expansion.isCollapsed(target))
    }

    /// 同じ投稿のブーストの行も、元の投稿と一緒に開く。
    @Test func boostSharesStateWithOriginal() {
        var expansion = SpoilerExpansion()
        let original = status(id: "10")
        let boost = status(id: "20", spoilerText: "", reblog: original)

        expansion.toggle(boost)
        #expect(!expansion.isCollapsed(original))
        #expect(!expansion.isCollapsed(boost))
    }

    /// 開閉を選んだ投稿は、あとからサーバーの設定が届いても、選んだ状態のままにする。
    @Test func choiceSurvivesLaterPreference() {
        var expansion = SpoilerExpansion()
        let target = status()
        expansion.toggle(target)

        expansion.expandsByDefault = false
        #expect(!expansion.isCollapsed(target))
        expansion.expandsByDefault = true
        expansion.toggle(target)
        #expect(expansion.isCollapsed(target))
    }
}
