import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.serialized)
struct TimelineContentTests {
    private func makeViewController() -> TimelineViewController {
        TimelineViewController(emojiImages: .offline)
    }

    @Test func bodyIsRenderedFromHTML() throws {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let status = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: #"<p>一行目<br />二行目</p><p><a href="https://example.social/tags/scia" class="mention hashtag" rel="tag">#<span>scia</span></a></p>"#,
            spoilerText: "",
            url: nil
        )

        let content = makeViewController().contentConfiguration(for: status, base: .cell())

        #expect(content.secondaryAttributedText?.string == "一行目\u{2028}二行目\n#scia")
    }
    @Test func setStatusesReflectsChangedContentOfSameID() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let original = StatusFactory.make(count: 5, startingAt: 100)
        harness.viewController.setStatuses(original)

        let edited = original.map { status in
            Status(
                id: status.id,
                createdAt: status.createdAt,
                account: status.account,
                content: "編集後: \(status.id)",
                spoilerText: status.spoilerText,
                url: status.url
            )
        }
        harness.viewController.setStatuses(edited)

        let firstID = try #require(edited.first?.id)
        #expect(harness.secondaryText(of: firstID) == "編集後: \(firstID)")
    }

    @Test func reblogShowsOriginalAuthorAndContent() throws {
        let original = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let booster = Account(
            id: "2",
            username: "bob",
            acct: "bob",
            displayName: "",
            avatar: original.account.avatar
        )
        let boost = Status(
            id: "200",
            createdAt: original.createdAt,
            account: booster,
            content: "",
            spoilerText: "",
            url: nil,
            reblog: original
        )

        let content = makeViewController().contentConfiguration(for: boost, base: .cell())

        #expect(content.attributedText?.string == "bobがブースト\n\(original.account.displayName)")
        #expect(content.secondaryAttributedText?.string == original.content)
    }

    @Test func spoilerHidesContent() throws {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let status = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: base.account,
            content: "<p>本文</p>",
            spoilerText: "ネタバレ",
            url: nil
        )

        let content = makeViewController().contentConfiguration(for: status, base: .cell())

        #expect(content.secondaryAttributedText?.string == "注意書き: ネタバレ")
    }
}
