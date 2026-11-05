import Foundation
import SciaCore
import Testing

/// 投稿のメニューの出し分けを確かめる。決まりはdocs/menus.mdにある。
@MainActor
struct StatusMenuTreeTests {
    private let alice = Account(id: "1", username: "alice", acct: "alice", displayName: "Alice", avatar: URL(string: "https://example.social/avatars/alice.png"))

    private func status(url: URL? = nil, account: Account? = nil, content: String = "<p>こんにちは</p>", mentions: [Mention] = [], reblog: Status? = nil, visibility: Status.Visibility = .public, tags: [SciaCore.Tag] = [], emojis: [CustomEmoji] = []) -> Status {
        Status(id: "100", createdAt: Date(timeIntervalSince1970: 100), account: account ?? alice, content: content, spoilerText: "", url: url, mentions: mentions, tags: tags, emojis: emojis, visibility: visibility, reblog: reblog)
    }

    private func account(_ id: String, _ acct: String) -> Account {
        Account(id: id, username: acct, acct: acct, displayName: acct, avatar: nil, url: URL(string: "https://example.social/@\(acct)"))
    }

    private func tree(_ status: Status?, notification: MastodonNotification? = nil, myAccountID: String? = nil, actions: UserMenuActions? = nil) -> StatusMenuTree {
        var tree = StatusMenuTree(status: status, notification: notification, now: Date(timeIntervalSince1970: 0), linkBrowser: .inApp)
        tree.myAccountID = myAccountID
        tree.userActions = actions
        tree.userMenu = MenuFixture.user.groups
        tree.hashtagMenu = MenuFixture.hashtag.groups
        return tree
    }

    private func outline(_ tree: StatusMenuTree, layout: MenuLayout<StatusMenuItem> = MenuFixture.status) -> String {
        MenuNodeTests.describe(tree.menu(groups: layout.groups, includesFollowRequest: true).root?.children ?? [])
    }

    private func titles(_ tree: StatusMenuTree, layout: MenuLayout<StatusMenuItem> = MenuFixture.status) -> [String] {
        func flatten(_ node: MenuNode<StatusMenuCommand>) -> [MenuNode<StatusMenuCommand>] {
            if case .action = node.content { return [node] }
            // ユーザーの`@acct`のサブメニューの中は含めない。
            guard !node.title.hasPrefix("@") else { return [] }
            return node.children.flatMap(flatten)
        }
        return (tree.menu(groups: layout.groups, includesFollowRequest: true).root?.children ?? []).flatMap(flatten).map(\.title)
    }

    private func showing(_ item: StatusMenuItem) -> MenuLayout<StatusMenuItem> {
        MenuLayout(elements: MenuFixture.status.elements.map { element in
            element == .item(item, isVisible: false) ? .item(item, isVisible: true) : element
        })
    }

    /// 既定の並びは、何のための操作かでまとまりを分ける。横並びの区切り線の下の返信・ブースト・お気に入りは横に並べる。
    /// 自分のアカウントが分からない一覧では、会話のミュート、固定、公開範囲を選んでブーストは出ない。
    @Test func defaultMenuGroupsItemsByPurpose() {
        #expect(outline(tree(status(url: URL(string: "https://example.social/@alice/100")))) == "=返信,ブースト(押せない),お気に入り|ブックマーク|共有,リンクをコピー,テキストをコピー,ブラウザで開く|翻訳|@alice[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]]|その他[カスタマイズ]")
    }

    /// 投稿を選べる一覧の行でだけ「選択」を出し、既定では「その他」の先頭に置く。投稿のない通知では出さない。
    @Test func selectItemAppearsOnlyWhereRowsCanBeSelected() {
        var selectable = tree(status())
        selectable.canSelectPosts = true
        let shown = titles(selectable)
        #expect(shown.contains("選択"))
        #expect(outline(selectable).contains("|その他[選択,"))
        #expect(!titles(tree(status())).contains("選択"))

        var withoutStatus = tree(nil)
        withoutStatus.canSelectPosts = true
        #expect(!titles(withoutStatus).contains("選択"))
    }

    /// 「リアクション」は、絵文字のリアクションに対応したサーバーでだけ出し、ブックマークと引用と同じまとまりに置く。
    @Test func emojiReactionAppearsOnlyOnSupportingServer() {
        var supporting = tree(status())
        supporting.supportsEmojiReactions = true
        #expect(outline(supporting).contains("|ブックマーク,リアクション|"))
        #expect(!titles(tree(status())).contains("リアクション"))
    }

    /// 本文が空白だけの投稿では、扱う文字がないのでテキストのコピーと翻訳を出さない。
    @Test func textItemsAreHiddenWithoutText() {
        let titles = titles(tree(status(content: "<p> </p>")))
        #expect(!titles.contains("テキストをコピー"))
        #expect(!titles.contains("翻訳"))
    }

    /// コピーや翻訳に渡す本文では、サーバーが縮めて見せるURLを元の文字のまま渡す。Mastodonのwebで本文を選んでコピーしたときと同じく、
    /// 見せずに残している先頭のスキームと後ろの部分を入れ、表示のために描いている「…」は入れない。
    @Test func plainTextKeepsShortenedURLsWhole() {
        let content = """
        <p>見て <a href="https://example.com/users/someone/status/2109995948407476369?s=46" rel="nofollow noopener" target="_blank"><span class="invisible">https://</span><span class="ellipsis">example.com/users/someone/stat</span><span class="invisible">us/2109995948407476369?s=46</span></a> と <a href="https://example.com/" rel="nofollow noopener" target="_blank"><span class="invisible">https://</span><span class="">example.com/</span><span class="invisible"></span></a></p>
        """
        #expect(StatusMenuTree.plainText(of: status(content: content))
            == "見て https://example.com/users/someone/status/2109995948407476369?s=46 と https://example.com/")
    }

    /// ブーストは元の投稿のページを指す。ブーストの側のurlがなくても、元の投稿にあれば押せる。urlがなければ押せないまま並べ、uriで代わりにしない。
    /// ユーザーは元の投稿を書いた人、ブーストした人の順に並ぶ。
    @Test func reblogUsesOriginalStatusURLAndListsBothUsers() throws {
        let original = status(url: URL(string: "https://remote.example/@bob/1"), account: account("2", "bob@remote.example"))
        let built = tree(status(reblog: original)).menu(groups: MenuFixture.status.groups, includesFollowRequest: true)
        let root = try #require(built.root)
        let links = root.flattenedChildren.filter { ["リンクをコピー", "共有", "ブラウザで開く"].contains($0.title) }

        #expect(links.count == 3)
        #expect(links.allSatisfy { $0.isEnabled })
        let users = try #require(root.children.dropLast().last)
        #expect(MenuNodeTests.describe([users]) == "@bob[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]],@alice[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]]")
        #expect(users.children.first?.subtitle == "remote.example")
        #expect(built.shownUserIDs == ["2", "1"])

        let withoutURL = try #require(tree(status()).menu(groups: MenuFixture.status.groups, includesFollowRequest: true).root)
        #expect(withoutURL.flattenedChildren.filter { ["リンクをコピー", "共有", "ブラウザで開く"].contains($0.title) }.allSatisfy { !$0.isEnabled })
    }

    /// 自分の投稿を自分でブーストしたときのように、同じユーザーが2つの項目に当たるときは1度だけ出す。
    @Test func sameUserIsListedOnce() {
        let built = tree(status(reblog: status())).menu(groups: MenuFixture.status.groups, includesFollowRequest: true)
        #expect(MenuNodeTests.describe(Array(built.root?.children.dropLast().suffix(1) ?? [])) == "@alice[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]]")
        #expect(built.shownUserIDs == ["1"])
    }

    /// 投稿のない通知では、通知したユーザーと、投稿を必要としない通知の削除だけを出す。通知したユーザーは、対象の投稿を書いた人より先に出る。
    @Test func notificationsListNotifyingUserFirst() {
        let follow = MastodonNotification(id: "1", type: .follow, createdAt: Date(timeIntervalSince1970: 0), account: account("2", "bob"))
        #expect(outline(tree(nil, notification: follow)) == "@bob[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]]|通知を削除|その他[カスタマイズ]")

        let favourite = MastodonNotification(id: "1", type: .favourite, createdAt: Date(timeIntervalSince1970: 0), account: account("2", "bob"), status: status())
        #expect(outline(tree(status(), notification: favourite)).hasSuffix("|@bob[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]],@alice[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]]|通知を削除|その他[カスタマイズ]"))
    }

    /// フォローリクエストの通知では、設定の並びの前に、承認と却下を置く。1項目だけ組むときは置かない。
    @Test func followRequestPutsDecisionsFirst() {
        let request = MastodonNotification(id: "1", type: .followRequest, createdAt: Date(timeIntervalSince1970: 0), account: account("2", "bob"))
        #expect(outline(tree(nil, notification: request)).hasPrefix("承認,却下!|@bob["))
        let single = tree(nil, notification: request).menu(groups: .single(.dismissNotification), includesFollowRequest: false).root
        #expect(MenuNodeTests.describe(single?.children ?? []) == "通知を削除")
    }

    /// 保留中の通知の行では、受け入れると無視を先に置き、その下にユーザーのメニューを並べる。ユーザーのメニューに出す項目がなければ2つだけにする。
    @Test func notificationRequestMenuPutsAnswersFirst() {
        let user = MenuNode<StatusMenuCommand>.submenu("@bob", [.action("プロフィール", .openThread)])
        #expect(MenuNodeTests.describe(StatusMenuTree.notificationRequestMenu(user: user).children) == "受け入れる,無視!|@bob[プロフィール]")
        #expect(MenuNodeTests.describe(StatusMenuTree.notificationRequestMenu(user: nil).children) == "受け入れる,無視!")
    }

    /// 「その他」より下の項目はサブメニューに入る。非表示の項目は出さず、区切り線で分けたまとまりに従う。
    @Test func itemsBelowMoreGoIntoSubmenu() {
        let layout = MenuLayout<StatusMenuItem>(elements: [
            .item(.reply, isVisible: true),
            .item(.favourite, isVisible: false),
            .separator,
            .item(.share, isVisible: true),
            .more,
            .item(.copyLink, isVisible: true),
            .separator,
            .item(.reblog, isVisible: true),
        ] + StatusMenuItem.allCases.filter { ![.reply, .favourite, .share, .copyLink, .reblog].contains($0) }.map { .item($0, isVisible: false) })

        #expect(outline(tree(status()), layout: layout) == "返信|共有(押せない)|その他[リンクをコピー(押せない),ブースト(押せない)]")
    }

    /// メンションされたユーザーは既定で隠す。出すと、メンションされた人ごとに並ぶ。
    @Test func mentionedUsersAreHiddenByDefaultAndListedWhenShown() {
        let mentions = [Mention(id: "3", username: "carol", url: nil, acct: "carol"), Mention(id: "4", username: "dave", url: nil, acct: "dave@remote.example")]
        let post = status(mentions: mentions)

        #expect(!outline(tree(post)).contains("@carol"))
        #expect(outline(tree(post), layout: showing(.mentionedUsers)).hasSuffix("|@alice[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]],@carol[プロフィール,リンクをコピー(押せない),共有(押せない),ブラウザで開く(押せない),その他[カスタマイズ]],@dave[プロフィール,リンクをコピー(押せない),共有(押せない),ブラウザで開く(押せない),その他[カスタマイズ]]|その他[カスタマイズ]"))
    }

    /// カスタム絵文字は、置く側が組んだ絵文字ごとのサブメニューで「その他」に並ぶ。絵文字のない投稿では出さない。
    @Test func customEmojisAreListedInMore() throws {
        let emojiURL = try #require(URL(string: "https://example.social/emoji/blobcat.png"))
        let emoji = CustomEmoji(shortcode: "blobcat", url: emojiURL, staticUrl: emojiURL)
        var withEmoji = tree(status(emojis: [emoji]))
        withEmoji.customEmoji = { (emoji: CustomEmoji) in
            var media = MediaMenuTree(kind: .image, attachment: emoji.attachment)
            media.open = true
            return media.customEmojiSubmenu(emoji, groups: MenuFixture.media.groups)
        }

        #expect(outline(withEmoji).hasSuffix("|その他[:blobcat:[開く,その他[メディアの情報[PNG],カスタマイズ]],カスタマイズ]"))
        #expect(!outline(tree(status())).contains(":"))
    }

    /// ハッシュタグは、関係するユーザーの後ろにタグごとの`#名前`のサブメニューで並ぶ。サーバーと同じ決まりでそろえた名前が同じタグは、1度だけ出す。
    @Test func hashtagsListHashtagMenuPerTagAfterUsers() throws {
        let tagURL = try #require(URL(string: "https://example.social/tags/cat"))
        let post = status(tags: [SciaCore.Tag(name: "cat", url: tagURL), SciaCore.Tag(name: "Cat", url: tagURL), SciaCore.Tag(name: "dog", url: nil)])

        #expect(outline(tree(post)).hasSuffix("|@alice[プロフィール,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]],#cat[すべての投稿,@aliceの投稿,リンクをコピー,共有,ブラウザで開く,その他[カスタマイズ]],#dog[すべての投稿,@aliceの投稿,リンクをコピー(押せない),共有(押せない),ブラウザで開く(押せない),その他[カスタマイズ]]|その他[カスタマイズ]"))
        #expect(!outline(tree(status())).contains("#"))
    }

    /// 会話のミュートは、自分の投稿、自分へのメンションを含む投稿、通知でだけ出る。
    @Test func conversationMuteIsShownOnlyWhereIAmInvolved() {
        let me = account("9", "me")
        let others = status()
        let notification = MastodonNotification(id: "1", type: .favourite, createdAt: Date(timeIntervalSince1970: 0), account: account("2", "bob"), status: others)

        #expect(!titles(tree(others, myAccountID: "9")).contains("会話をミュート"))
        #expect(titles(tree(status(account: me), myAccountID: "9")).contains("会話をミュート"))
        #expect(titles(tree(status(mentions: [Mention(id: "9", username: "me", url: nil, acct: "me")]), myAccountID: "9")).contains("会話をミュート"))
        #expect(titles(tree(others, notification: notification, myAccountID: "9")).contains("会話をミュート"))
    }

    /// プロフィールへの固定は、ダイレクトではない自分の投稿でだけ出る。自分の投稿でだけ、編集、削除して書き直す、削除を出す。
    @Test func ownPostItems() {
        let me = account("9", "me")

        #expect(titles(tree(status(account: me), myAccountID: "9")).contains("プロフィールに固定"))
        #expect(!titles(tree(status(account: me, visibility: .direct), myAccountID: "9")).contains("プロフィールに固定"))
        #expect(!titles(tree(status(), myAccountID: "9")).contains("プロフィールに固定"))
        #expect(titles(tree(status(account: me), myAccountID: "9")).contains("削除"))
        #expect(!titles(tree(status(), myAccountID: "9")).contains("削除"))
        #expect(titles(tree(status(account: me), myAccountID: "9")).contains("削除して書き直す"))
        #expect(!titles(tree(status(), myAccountID: "9")).contains("削除して書き直す"))
    }

    /// 公開範囲を選んでブーストは、既定では隠す。出したときは、ブーストしていない投稿で、3つの公開範囲のサブメニューとして出る。ブーストした投稿では出さない。
    @Test func reblogWithVisibilityIsSubmenuOnlyBeforeBoosting() {
        let submenu = "公開範囲を選んでブースト[公開,ひかえめな公開,フォロワーのみ]"

        #expect(!outline(tree(status(), myAccountID: "9")).contains(submenu))
        #expect(outline(tree(status(), myAccountID: "9"), layout: showing(.reblogWithVisibility)).contains(submenu))
        #expect(!outline(tree(status().settingReblogged(true), myAccountID: "9"), layout: showing(.reblogWithVisibility)).contains(submenu))
    }

    /// 状態で名前とアイコンを切り替える。お気に入りしていれば取り消し、押せないときは理由を添える。
    @Test func itemsFollowStatusState() throws {
        let built = tree(status().settingFavourited(true), myAccountID: "9").menu(groups: .single(.favourite), includesFollowRequest: false)
        let favourite = try #require(built.root?.flattenedChildren.first)
        #expect(favourite.title == "お気に入りを取り消す")
        #expect(favourite.icon?.symbolName == "star.slash")

        // 自分のアカウントが分からない一覧では、ブーストできるかを決められないので押せない。
        guard case .unavailable(let reason) = MenuItemOutcome(singleItemMenu: tree(status()).menu(groups: .single(.reblog), includesFollowRequest: false).root) else {
            Issue.record("ブーストできない投稿で押せてしまいます")
            return
        }
        #expect(reason == nil)
    }

    /// 画面の状態で決まる項目は、置く側が渡した状態に従う。
    /// 「APIの応答」は既定では隠し、出すと「その他」の中に並ぶ。
    @Test func apiResponseIsHiddenByDefaultAndListedInMoreWhenShown() {
        #expect(!titles(tree(status())).contains("APIの応答"))
        #expect(outline(tree(status()), layout: showing(.apiResponse)).hasSuffix("|その他[APIの応答,カスタマイズ]"))
    }

    @Test func screenStateItems() {
        var open = tree(status())
        #expect(!titles(open, layout: showing(.openThread)).contains("スレッドを開く"))
        open.canOpenThread = true
        #expect(titles(open, layout: showing(.openThread)).contains("スレッドを開く"))

        let attachment = MediaAttachment(id: "1", type: .image, url: nil, previewUrl: nil, description: nil, meta: nil)
        let withMedia = Status(id: "100", createdAt: Date(timeIntervalSince1970: 100), account: alice, content: "<p>a</p>", spoilerText: "", url: nil, mediaAttachments: [attachment])
        var media = tree(withMedia)
        #expect(titles(media, layout: showing(.hideMedia)).contains("画像を隠す"))
        media.mediaIsCovered = true
        #expect(!titles(media, layout: showing(.hideMedia)).contains("画像を隠す"))
    }
}
