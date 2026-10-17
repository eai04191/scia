import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.serialized)
struct TimelineContentTests {
    private func makeViewController() -> TimelineViewController {
        TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline)
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

        #expect(content.body.string == "一行目\u{2028}二行目\n#scia")
    }
    @Test func favouriteNotificationShowsActorAndTargetStatus() throws {
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let actor = Account(id: "2", username: "bob", acct: "bob@remote.example", displayName: "Bob", avatar: status.account.avatar)
        let notification = MastodonNotification(id: "1", type: .favourite, createdAt: .now, account: actor, status: status)

        let content = try #require(makeViewController().contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)

        #expect(content.header.string == "\u{FFFC} Bobがお気に入りに登録しました")
        #expect(content.body.text.string == makeViewController().body(of: status, base: .cell()).string)
        #expect(content.symbolName == "star.fill")
    }

    /// メンションはホームの投稿と同じ見た目にし、名前の上に誰が何をしたかの行を足す。
    @Test func mentionLooksLikePostWithContext() throws {
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let notification = MastodonNotification(id: "1", type: .mention, createdAt: .now, account: status.account, status: status)

        let content = try #require(makeViewController().contentConfiguration(for: notification, base: .cell()) as? PostContentConfiguration)

        #expect(content.context?.text.string == "\(status.account.displayNameOrUsername)からのメンション")
        #expect(content.context?.symbolName == "at")
        #expect(content.body.string == makeViewController().body(of: status, base: .cell()).string)
    }

    /// 再掲する本文は、チューニングの行数で切る。
    @Test func quotedBodyIsTruncatedByTuning() throws {
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let notification = MastodonNotification(id: "1", type: .reblog, createdAt: .now, account: status.account, status: status)
        let tuning = TuningStore(defaults: nil)
        tuning.setValue(5, for: TuningCatalog.notificationQuotedBodyLines)
        let vc = TimelineViewController(tuning: tuning, emojiImages: .offline, avatarImages: .offline)

        let content = try #require(vc.contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)

        #expect(content.body.maximumLines == 5)
    }

    @Test func followNotificationShowsAccountAddress() throws {
        let avatar = try #require(StatusFactory.make(count: 1, startingAt: 100).first?.account.avatar)
        let actor = Account(id: "2", username: "bob", acct: "bob@remote.example", displayName: "", avatar: avatar)
        let notification = MastodonNotification(id: "1", type: .follow, createdAt: .now, account: actor)

        let content = try #require(makeViewController().contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)

        #expect(content.header.string == "\u{FFFC} bobにフォローされました")
        #expect(content.body.text.string == "@bob@remote.example")
        #expect(content.body.media == nil)
    }

    @Test func unknownNotificationTypeStillShowsActor() throws {
        let avatar = try #require(StatusFactory.make(count: 1, startingAt: 100).first?.account.avatar)
        let actor = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: avatar)
        let notification = MastodonNotification(id: "1", type: .other("admin.sign_up"), createdAt: .now, account: actor)

        let content = try #require(makeViewController().contentConfiguration(for: notification, base: .cell()) as? NotificationContentConfiguration)

        #expect(content.header.string == "\u{FFFC} Bobからの通知（admin.sign_up）")
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

        #expect(content.context?.text.string == "bob")
        #expect(content.context?.avatar?.url == booster.avatarStatic)
        #expect(content.avatar.url == original.account.avatarStatic)
        #expect(content.nameParts.map(\.string) == [original.account.displayName, "@\(original.account.acct)"])
        #expect(content.createdAt == original.createdAt)
        #expect(content.body.string == original.content)
    }

    @Test func tappingAvatarOpensAuthorAndContextOpensBooster() throws {
        let original = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let booster = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: original.account.avatar)
        let boost = Status(id: "200", createdAt: original.createdAt, account: booster, content: "", spoilerText: "", url: nil, reblog: original)
        let controller = makeViewController()
        var opened: [Account.ID] = []
        controller.onOpenProfile = { opened.append($0.id) }

        let content = controller.contentConfiguration(for: boost, base: .cell())
        content.onOpenAccount?()
        content.onOpenContextAccount?()

        #expect(opened == [original.account.id, booster.id])
    }

    @Test func pinnedStatusShowsPinnedRowWithoutAccount() throws {
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)

        let content = makeViewController().contentConfiguration(for: status, isPinned: true, base: .cell())

        #expect(content.context?.text.string == "固定された投稿")
        #expect(content.context?.avatar == nil)
        #expect(content.onOpenContextAccount == nil)
    }

    private func color(of text: NSAttributedString?) -> UIColor? {
        text?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
    }

    /// 本文は読むものなので、いちばん濃い文字色にする。
    @Test func postBodyUsesPrimaryColor() throws {
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)

        let content = makeViewController().contentConfiguration(for: status, base: .cell())

        #expect(color(of: content.body) == .label)
    }

    /// 会話にあたる通知の本文は濃くし、自分の投稿へのお気に入りやブーストの通知では、再掲の本文を控えめにして誰が何をしたかを目立たせる。
    @Test(arguments: [
        (MastodonNotification.Kind.mention, UIColor.label),
        (.favourite, .secondaryLabel),
        (.reblog, .secondaryLabel),
    ])
    func notificationBodyColorDependsOnKind(_ kind: MastodonNotification.Kind, expected: UIColor) throws {
        let status = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let notification = MastodonNotification(id: "1", type: kind, createdAt: .now, account: status.account, status: status)

        let content = makeViewController().contentConfiguration(for: notification, base: .cell())
        let body = (content as? PostContentConfiguration)?.body ?? (content as? NotificationContentConfiguration)?.body.text

        #expect(color(of: body) == expected)
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

        #expect(content.spoiler?.text.string == "ネタバレ")
        #expect(content.spoiler?.isCollapsed == true)
    }

    /// 末尾のフッターは一覧の最後に置き、表示範囲の下端に貼り付けない。
    /// 貼り付くと、中身のない透明なフッターがタブバーのすぐ上を覆い、そこにある画像などをタップできなかった。
    @Test func footerStaysAtEndOfListInsteadOfPinningToVisibleBounds() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 40, startingAt: 1_000))
        harness.scroll(toFraction: 0.5)

        let collectionView = harness.collectionView
        let footers = collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter)
        for footer in footers {
            #expect(abs(footer.frame.maxY - collectionView.contentSize.height) < 0.5, "フッターが一覧の途中に出ています: \(footer.frame)")
        }
    }
}
