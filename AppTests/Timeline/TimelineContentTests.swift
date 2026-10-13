import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.serialized)
struct TimelineContentTests {
    private func makeViewController() -> TimelineViewController {
        TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline)
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
    @Test func favouriteNotificationShowsActorAndTargetStatus() throws {
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let actor = Account(id: "2", username: "bob", acct: "bob@remote.example", displayName: "Bob", avatar: status.account.avatar)
        let notification = MastodonNotification(id: "1", type: .favourite, createdAt: .now, account: actor, status: status)

        let content = makeViewController().contentConfiguration(for: notification, base: .cell())

        #expect(content.attributedText?.string == "Bobがお気に入りに登録しました")
        #expect(content.secondaryAttributedText?.string == makeViewController().body(of: status, base: .cell()).string)
        #expect(content.image != nil)
    }

    @Test func followNotificationShowsAccountAddress() throws {
        let avatar = try #require(StatusFactory.make(count: 1, startingAt: 100).first?.account.avatar)
        let actor = Account(id: "2", username: "bob", acct: "bob@remote.example", displayName: "", avatar: avatar)
        let notification = MastodonNotification(id: "1", type: .follow, createdAt: .now, account: actor)

        let content = makeViewController().contentConfiguration(for: notification, base: .cell())

        #expect(content.attributedText?.string == "bobにフォローされました")
        #expect(content.secondaryAttributedText?.string == "@bob@remote.example")
    }

    @Test func unknownNotificationTypeStillShowsActor() throws {
        let avatar = try #require(StatusFactory.make(count: 1, startingAt: 100).first?.account.avatar)
        let actor = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: avatar)
        let notification = MastodonNotification(id: "1", type: .other("admin.sign_up"), createdAt: .now, account: actor)

        let content = makeViewController().contentConfiguration(for: notification, base: .cell())

        #expect(content.attributedText?.string == "Bobからの通知（admin.sign_up）")
    }

    @Test func setEntriesReflectsChangedContentOfSameID() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        let original = StatusFactory.make(count: 5, startingAt: 100)
        harness.setStatuses(original)

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
        harness.setStatuses(edited)

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
