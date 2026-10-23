import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct StatusMenuTests {
    private func makeSettings() throws -> AppSettings {
        let suite = "StatusMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    /// - Parameter myAccountID: 自分のアカウントのID。自分の投稿でだけ出る項目を試すときに渡す。
    /// - Parameter userMenuActions: ユーザーのメニューのメンションとハンドルをコピーを組むもの。渡さなければ2つは出ない。
    private func menu(for entry: TimelineEntry, settings: AppSettings? = nil, myAccountID: String? = nil, userMenuActions: UserMenuActions? = nil) throws -> UIMenu? {
        let viewController = TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: try settings ?? makeSettings())
        viewController.myAccountID = myAccountID
        viewController.userMenuActions = userMenuActions
        return viewController.contextMenu(for: entry, id: entry.id)
    }

    private func status(url: URL?, account: Account? = nil, content: String? = nil, mentions: [Mention] = [], reblog: Status? = nil) throws -> Status {
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        return Status(id: base.id, createdAt: base.createdAt, account: account ?? base.account, content: content ?? base.content, spoilerText: "", url: url, mentions: mentions, reblog: reblog)
    }

    private func account(_ id: String, _ acct: String) throws -> Account {
        let avatar = try #require(StatusFactory.make(count: 1, startingAt: 100).first?.account.avatar)
        return Account(id: id, username: acct, acct: acct, displayName: acct, avatar: avatar)
    }

    /// まとまりごとの項目の名前。サブメニューは`名前[中身]`、サブタイトルのあるサブメニューは`名前(サブタイトル)[中身]`で表す。
    private func outline(_ menu: UIMenu?) -> [[String]] {
        (menu?.children ?? []).map { element in
            guard let group = element as? UIMenu, group.options.contains(.displayInline) else { return [describe(element)] }
            return group.children.map(describe)
        }
    }

    /// 関係の項目は開いてから読むため、`…`で表す。
    private func describe(_ element: UIMenuElement) -> String {
        if element is UIDeferredMenuElement { return "…" }
        guard let menu = element as? UIMenu else { return element.title }
        let children = menu.children.flatMap { child in (child as? UIMenu)?.options.contains(.displayInline) == true ? (child as? UIMenu)?.children ?? [] : [child] }
        let subtitle = menu.subtitle.map { "(\($0))" } ?? ""
        return "\(menu.title)\(subtitle)[\(children.map(describe).joined(separator: ","))]"
    }

    /// 投稿への操作。ユーザーの`@acct`のサブメニューの中は含めない。
    private func actions(_ menu: UIMenu?) -> [UIAction] {
        func flatten(_ element: UIMenuElement) -> [UIAction] {
            if let action = element as? UIAction { return [action] }
            guard let menu = element as? UIMenu, !menu.title.hasPrefix("@") else { return [] }
            return menu.children.flatMap(flatten)
        }
        return (menu?.children ?? []).flatMap(flatten)
    }

    /// 既定の並びは、何のための操作かでまとまりを分ける。
    /// 自分のアカウントが分からない一覧では、会話のミュート、固定、公開範囲を選んでブーストは出ない。
    @Test func defaultMenuGroupsItemsByPurpose() throws {
        let post = try status(url: URL(string: "https://example.social/@alice/100"))

        #expect(try outline(menu(for: .status(post))) == [
            ["返信", "お気に入り", "ブースト"],
            ["ブックマーク"],
            ["リンクをコピー", "テキストをコピー", "共有", "ブラウザで開く"],
            ["翻訳"],
            ["@alice[プロフィール,リンクをコピー,共有,ブラウザで開く]"],
        ])
    }

    /// 本文が空白だけの投稿では、扱う文字がないのでテキストのコピーと翻訳を出さない。
    @Test func textItemsAreHiddenWithoutText() throws {
        let titles = try actions(menu(for: .status(status(url: nil, content: "<p> </p>")))).map(\.title)

        #expect(!titles.contains("テキストをコピー"))
        #expect(!titles.contains("翻訳"))
    }

    /// ブーストは元の投稿のページを指す。ブーストの側のurlがなくても、元の投稿にあれば押せる。
    /// ユーザーは元の投稿を書いた人、ブーストした人の順に並ぶ。
    @Test func reblogUsesOriginalStatusURLAndListsBothUsers() throws {
        let original = try status(url: URL(string: "https://remote.example/@bob/1"), account: account("2", "bob@remote.example"))
        let menu = try menu(for: .status(status(url: nil, reblog: original)))

        let links = actions(menu).filter { ["リンクをコピー", "共有", "ブラウザで開く"].contains($0.title) }
        #expect(links.count == 3)
        #expect(links.allSatisfy { !$0.attributes.contains(.disabled) })
        #expect(outline(menu).last == ["@bob(remote.example)[プロフィール,リンクをコピー,共有,ブラウザで開く]", "@alice[プロフィール,リンクをコピー,共有,ブラウザで開く]"])
    }

    /// urlはAPIでnullを取りうる。ないときは押せないまま並べ、uriで代わりにしない。
    @Test func linkActionsAreDisabledWithoutURL() throws {
        let links = try actions(menu(for: .status(status(url: nil)))).filter { ["リンクをコピー", "共有", "ブラウザで開く"].contains($0.title) }

        #expect(links.count == 3)
        #expect(links.allSatisfy { $0.attributes.contains(.disabled) })
    }

    /// 自分の投稿を自分でブーストしたときのように、同じユーザーが2つの項目に当たるときは1度だけ出す。
    @Test func sameUserIsListedOnce() throws {
        let original = try status(url: nil)
        let menu = try menu(for: .status(status(url: nil, reblog: original)))

        #expect(outline(menu).last == ["@alice[プロフィール,リンクをコピー,共有,ブラウザで開く]"])
    }

    /// 投稿のない通知では、通知したユーザーと、投稿を必要としない通知の削除だけを出す。
    @Test func followNotificationShowsOnlyNotifyingUserAndDismiss() throws {
        let notification = MastodonNotification(id: "1", type: .follow, createdAt: .now, account: try account("2", "bob"))

        #expect(try outline(menu(for: .notification(notification))) == [["@bob[プロフィール,リンクをコピー,共有,ブラウザで開く]"], ["その他[通知を削除]"]])
    }

    /// 通知したユーザーは、対象の投稿を書いた人より先に出る。
    @Test func notificationListsNotifyingUserBeforeAuthor() throws {
        let notification = MastodonNotification(id: "1", type: .favourite, createdAt: .now, account: try account("2", "bob"), status: try status(url: nil))

        // 最後のまとまりは、通知の削除を入れた「その他」。
        #expect(try outline(menu(for: .notification(notification))).dropLast().last == ["@bob[プロフィール,リンクをコピー,共有,ブラウザで開く]", "@alice[プロフィール,リンクをコピー,共有,ブラウザで開く]"])
    }

    /// 「その他」より下の項目はサブメニューに入る。非表示の項目は出さず、区切り線で分けたまとまりに従う。
    @Test func itemsBelowMoreGoIntoSubmenu() throws {
        let settings = try makeSettings()
        settings.statusMenuLayout = MenuLayout(elements: [
            .item(.reply, isVisible: true),
            .item(.favourite, isVisible: false),
            .separator,
            .item(.share, isVisible: true),
            .more,
            .item(.copyLink, isVisible: true),
            .separator,
            .item(.reblog, isVisible: true),
        ])

        let outline = try outline(menu(for: .status(status(url: nil)), settings: settings))

        // 並びに書かなかった項目は、既定で直前にある項目の後ろに差し込まれる。ブラウザで開くと翻訳は共有の後ろに、ユーザーの項目はその後ろに、テキストのコピーはリンクのコピーの後ろに、ブックマークはブーストの後ろに入る。
        #expect(outline == [
            ["返信"],
            ["共有", "ブラウザで開く", "翻訳", "@alice[プロフィール,リンクをコピー,共有,ブラウザで開く]"],
            ["その他[リンクをコピー,テキストをコピー,ブースト,ブックマーク]"],
        ])
    }

    /// ユーザーのメニューの中身が1つで「その他」が空なら、サブメニューにせず直接並べる。
    @Test func singleUserMenuItemIsListedDirectly() throws {
        let settings = try makeSettings()
        settings.userMenuLayout = MenuLayout(elements: UserMenuItem.allCases.map { .item($0, isVisible: $0 == .profile) } + [.more])

        let outline = try outline(menu(for: .status(status(url: nil)), settings: settings))

        #expect(outline.last == ["@aliceのプロフィール"])
    }

    /// 既定のユーザーのメニューは、開く・書く操作、フォロー、持ち出す操作でまとまりを分け、フォローの設定、ミュート、ブロックは「その他」に入れる。
    /// 関係の項目は、開いてから読む。開く場所を選んで開く2つは隠れている。
    @Test func defaultUserMenuHasMentionAndCopyUsername() throws {
        let actions = UserMenuActions(mention: { _ in }, copyHandle: { _, _ in }, loadRelation: { _ in nil }, changeRelation: { _, _ in }, report: { _, _ in }, cachedAccount: { _ in nil }, loadAccount: { _ in throw CancellationError() })

        let outline = try outline(menu(for: .status(status(url: nil)), userMenuActions: actions))

        #expect(outline.last == ["@alice[プロフィール,メンション,…,ハンドルをコピー,リンクをコピー,共有,ブラウザで開く,その他[…,…,…,…,…]]"])
    }

    /// メンション、ハンドルをコピー、関係の項目を組むものを渡されていない画面では、これらを出さない。
    @Test func userMenuOmitsMentionAndCopyUsernameWithoutActions() throws {
        let outline = try outline(menu(for: .status(status(url: nil))))

        #expect(outline.last == ["@alice[プロフィール,リンクをコピー,共有,ブラウザで開く]"])
    }

    /// 関係の項目は、1つだけでもサブメニューにする。読んでから中身が決まり、名前に相手を入れられないため。
    @Test func singleRelationItemStaysInSubmenu() throws {
        let settings = try makeSettings()
        settings.userMenuLayout = MenuLayout(elements: UserMenuItem.allCases.map { .item($0, isVisible: $0 == .follow) } + [.more])
        let actions = UserMenuActions(mention: { _ in }, copyHandle: { _, _ in }, loadRelation: { _ in nil }, changeRelation: { _, _ in }, report: { _, _ in }, cachedAccount: { _ in nil }, loadAccount: { _ in throw CancellationError() })

        let outline = try outline(menu(for: .status(status(url: nil)), settings: settings, userMenuActions: actions))

        #expect(outline.last == ["@alice[…]"])
    }

    /// サブメニューにせず直接並べるときは、メンションの名前に相手を入れる。
    @Test func singleMentionItemIsListedDirectlyWithAcct() throws {
        let settings = try makeSettings()
        settings.userMenuLayout = MenuLayout(elements: UserMenuItem.allCases.map { .item($0, isVisible: $0 == .mention) } + [.more])
        let actions = UserMenuActions(mention: { _ in }, copyHandle: { _, _ in }, loadRelation: { _ in nil }, changeRelation: { _, _ in }, report: { _, _ in }, cachedAccount: { _ in nil }, loadAccount: { _ in throw CancellationError() })

        let outline = try outline(menu(for: .status(status(url: nil)), settings: settings, userMenuActions: actions))

        #expect(outline.last == ["@aliceにメンション"])
    }

    /// ユーザーのメニューの中身が2つ以上か、「その他」に何かあれば、@acctのサブメニューにする。
    @Test func userMenuBecomesSubmenuWhenProfileIsInMore() throws {
        let settings = try makeSettings()
        settings.userMenuLayout = MenuLayout(elements: [.more, .item(.profile, isVisible: true)])

        let outline = try outline(menu(for: .status(status(url: nil)), settings: settings))

        #expect(outline.last == ["@alice[その他[プロフィール,リンクをコピー,共有,ブラウザで開く]]"])
    }

    /// ユーザーのメニューに出す項目がなければ、ユーザーの項目を出さない。
    @Test func emptyUserMenuHidesUserItems() throws {
        let settings = try makeSettings()
        settings.userMenuLayout = MenuLayout(elements: UserMenuItem.allCases.map { .item($0, isVisible: false) } + [.more])

        let outline = try outline(menu(for: .status(status(url: nil)), settings: settings))

        #expect(!outline.joined().contains { $0.contains("@alice") })
    }

    /// メンションされたユーザーのアイコンは、一覧のほかの行にいるその人のアカウントから取る。ブーストされた投稿を書いた人と、通知した人からも探す。
    @Test func mentionedAccountIsFoundInOtherRows() throws {
        let boost = try status(url: nil, reblog: try status(url: nil, account: try account("3", "carol")))
        let notification = MastodonNotification(id: "1", type: .follow, createdAt: .now, account: try account("4", "dave"))
        let entries: [TimelineEntry] = [.status(boost), .notification(notification)]

        #expect(TimelineViewController.account(withID: "3", in: entries)?.acct == "carol")
        #expect(TimelineViewController.account(withID: "4", in: entries)?.acct == "dave")
        #expect(TimelineViewController.account(withID: "5", in: entries) == nil)
    }

    /// メンションされたユーザーは既定で隠す。出すと、メンションされた人ごとに並ぶ。
    @Test func mentionedUsersAreHiddenByDefaultAndListedWhenShown() throws {
        let mentions = [Mention(id: "3", username: "carol", url: nil, acct: "carol"), Mention(id: "4", username: "dave", url: nil, acct: "dave@remote.example")]
        let post = try status(url: nil, mentions: mentions)
        #expect(try !outline(menu(for: .status(post))).joined().contains("@carol[プロフィール,リンクをコピー,共有,ブラウザで開く]"))

        let settings = try makeSettings()
        settings.statusMenuLayout = MenuLayout(elements: StatusMenuItem.defaultLayout.elements.map { element in
            element == .item(.mentionedUsers, isVisible: false) ? .item(.mentionedUsers, isVisible: true) : element
        })

        #expect(try outline(menu(for: .status(post), settings: settings)).last == ["@alice[プロフィール,リンクをコピー,共有,ブラウザで開く]", "@carol[プロフィール,リンクをコピー,共有,ブラウザで開く]", "@dave(remote.example)[プロフィール,リンクをコピー,共有,ブラウザで開く]"])
    }

    /// カスタム絵文字は「その他」に、絵文字ごとの`:shortcode:`のサブメニューで並び、中に絵文字の画像のメディアのメニューを出す。
    /// 投稿のメニューの中なので、メディアのメニューの「投稿」は出さない。
    @Test func customEmojisListMediaMenuPerEmojiInMore() throws {
        let emojiURL = try #require(URL(string: "https://example.social/emoji/blobcat.png"))
        let base = try status(url: nil)
        let post = Status(
            id: base.id, createdAt: base.createdAt, account: base.account, content: base.content, spoilerText: "", url: nil,
            emojis: [CustomEmoji(shortcode: "blobcat", url: emojiURL, staticUrl: emojiURL)]
        )

        let more = try #require(menu(for: .status(post))?.children.last as? UIMenu)
        #expect(more.title == "その他")
        let emoji = try #require(more.children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }.first { $0.title == ":blobcat:" })
        #expect(describe(emoji) == ":blobcat:[開く,リンクをコピー,ブラウザで開く,その他[メディアの情報[PNG]]]")
    }

    /// カスタム絵文字のない投稿では、カスタム絵文字の項目を出さない。
    @Test func customEmojisAreHiddenWithoutEmojis() throws {
        let titles = try outline(menu(for: .status(status(url: nil)))).joined()

        #expect(!titles.contains { $0.contains("カスタム絵文字") || $0.hasPrefix(":") })
    }

    /// 横並びの区切り線の下のまとまりは、中くらいの大きさで横に並べる。既定では返信・お気に入り・ブーストのまとまりだけが横並びになる。
    @Test func rowSeparatorMakesFollowingGroupMediumSized() throws {
        let post = try status(url: nil)
        let groups = try menu(for: .status(post))?.children.compactMap { $0 as? UIMenu } ?? []

        #expect(groups.first?.preferredElementSize == .medium)
        #expect(groups.dropFirst().allSatisfy { $0.preferredElementSize != .medium })

        let settings = try makeSettings()
        settings.statusMenuLayout = MenuLayout(elements: StatusMenuItem.defaultLayout.elements.filter { $0 != .rowSeparator })
        let withoutRow = try menu(for: .status(post), settings: settings)?.children.compactMap { $0 as? UIMenu } ?? []

        #expect(withoutRow.allSatisfy { $0.preferredElementSize != .medium })
    }

    /// 会話のミュートは、自分の投稿、自分へのメンションを含む投稿、通知でだけ出る。
    @Test func conversationMuteIsShownOnlyWhereIAmInvolved() throws {
        let me = try account("9", "me")
        let others = try status(url: nil)
        let mine = try status(url: nil, account: me)
        let mentioningMe = try status(url: nil, mentions: [Mention(id: "9", username: "me", url: nil, acct: "me")])
        func titles(_ entry: TimelineEntry) throws -> [String] { try actions(menu(for: entry, myAccountID: "9")).map(\.title) }

        #expect(try !titles(.status(others)).contains("会話をミュート"))
        #expect(try titles(.status(mine)).contains("会話をミュート"))
        #expect(try titles(.status(mentioningMe)).contains("会話をミュート"))
        let notification = MastodonNotification(id: "1", type: .favourite, createdAt: .now, account: try account("2", "bob"), status: others)
        #expect(try titles(.notification(notification)).contains("会話をミュート"))
    }

    /// プロフィールへの固定は、ダイレクトではない自分の投稿でだけ出る。
    @Test func pinIsShownOnlyForOwnPinnablePosts() throws {
        let me = try account("9", "me")
        let base = try status(url: nil, account: me)
        let direct = Status(id: base.id, createdAt: base.createdAt, account: me, content: base.content, spoilerText: "", url: nil, visibility: .direct)
        func titles(_ status: Status) throws -> [String] { try actions(menu(for: .status(status), myAccountID: "9")).map(\.title) }

        #expect(try titles(base).contains("プロフィールに固定"))
        #expect(try !titles(direct).contains("プロフィールに固定"))
        #expect(try !titles(status(url: nil)).contains("プロフィールに固定"))
    }

    /// 公開範囲を選んでブーストは、既定では隠す。出したときは、ブーストしていない投稿で、3つの公開範囲のサブメニューとして出る。ブーストした投稿では出さない。
    @Test func reblogWithVisibilityIsSubmenuOnlyBeforeBoosting() throws {
        let post = try status(url: nil)
        let submenu = "公開範囲を選んでブースト[公開,ひかえめな公開,フォロワーのみ]"
        #expect(try !outline(menu(for: .status(post), myAccountID: "9")).joined().contains(submenu))

        let settings = try makeSettings()
        settings.statusMenuLayout = MenuLayout(elements: StatusMenuItem.defaultLayout.elements.map { element in
            element == .item(.reblogWithVisibility, isVisible: false) ? .item(.reblogWithVisibility, isVisible: true) : element
        })

        #expect(try outline(menu(for: .status(post), settings: settings, myAccountID: "9")).joined().contains(submenu))
        #expect(try !outline(menu(for: .status(post.settingReblogged(true)), settings: settings, myAccountID: "9")).joined().contains(submenu))
    }
}
