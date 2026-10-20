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

    private func menu(for entry: TimelineEntry, settings: AppSettings? = nil) throws -> UIMenu? {
        let viewController = TimelineViewController(tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: try settings ?? makeSettings())
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

    private func describe(_ element: UIMenuElement) -> String {
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

    /// 既定の並びは、設定を足す前のメニューと同じにする。
    @Test func defaultMenuMatchesMenuBeforeCustomization() throws {
        let post = try status(url: URL(string: "https://example.social/@alice/100"))

        #expect(try outline(menu(for: .status(post))) == [
            ["返信", "お気に入り", "ブースト"],
            ["リンクをコピー", "テキストをコピー", "共有", "ブラウザで開く", "翻訳"],
            ["@alice[プロフィール,リンクをコピー,共有]"],
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
        #expect(outline(menu).last == ["@bob(remote.example)[プロフィール,リンクをコピー,共有]", "@alice[プロフィール,リンクをコピー,共有]"])
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

        #expect(outline(menu).last == ["@alice[プロフィール,リンクをコピー,共有]"])
    }

    /// 投稿のない通知では、通知したユーザーだけを出す。
    @Test func followNotificationShowsOnlyNotifyingUser() throws {
        let notification = MastodonNotification(id: "1", type: .follow, createdAt: .now, account: try account("2", "bob"))

        #expect(try outline(menu(for: .notification(notification))) == [["@bob[プロフィール,リンクをコピー,共有]"]])
    }

    /// 通知したユーザーは、対象の投稿を書いた人より先に出る。
    @Test func notificationListsNotifyingUserBeforeAuthor() throws {
        let notification = MastodonNotification(id: "1", type: .favourite, createdAt: .now, account: try account("2", "bob"), status: try status(url: nil))

        #expect(try outline(menu(for: .notification(notification))).last == ["@bob[プロフィール,リンクをコピー,共有]", "@alice[プロフィール,リンクをコピー,共有]"])
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

        // 並びに書かなかった項目は、既定で直前にある項目の後ろに差し込まれる。ブラウザで開くと翻訳は共有の後ろに、ユーザーの項目はその後ろに、テキストのコピーはリンクのコピーの後ろに入る。
        #expect(outline == [
            ["返信"],
            ["共有", "ブラウザで開く", "翻訳", "@alice[プロフィール,リンクをコピー,共有]"],
            ["その他[リンクをコピー,テキストをコピー,ブースト]"],
        ])
    }

    /// ユーザーのメニューの中身が1つで「その他」が空なら、サブメニューにせず直接並べる。
    @Test func singleUserMenuItemIsListedDirectly() throws {
        let settings = try makeSettings()
        settings.userMenuLayout = MenuLayout(elements: [.item(.profile, isVisible: true), .item(.copyLink, isVisible: false), .item(.share, isVisible: false), .more])

        let outline = try outline(menu(for: .status(status(url: nil)), settings: settings))

        #expect(outline.last == ["@aliceのプロフィール"])
    }

    /// ユーザーのメニューの中身が2つ以上か、「その他」に何かあれば、@acctのサブメニューにする。
    @Test func userMenuBecomesSubmenuWhenProfileIsInMore() throws {
        let settings = try makeSettings()
        settings.userMenuLayout = MenuLayout(elements: [.more, .item(.profile, isVisible: true)])

        let outline = try outline(menu(for: .status(status(url: nil)), settings: settings))

        #expect(outline.last == ["@alice[その他[プロフィール,リンクをコピー,共有]]"])
    }

    /// ユーザーのメニューに出す項目がなければ、ユーザーの項目を出さない。
    @Test func emptyUserMenuHidesUserItems() throws {
        let settings = try makeSettings()
        settings.userMenuLayout = MenuLayout(elements: [.item(.profile, isVisible: false), .item(.copyLink, isVisible: false), .item(.share, isVisible: false), .more])

        let outline = try outline(menu(for: .status(status(url: nil)), settings: settings))

        #expect(!outline.joined().contains { $0.contains("@alice") })
    }

    /// メンションされたユーザーは既定で隠す。出すと、メンションされた人ごとに並ぶ。
    @Test func mentionedUsersAreHiddenByDefaultAndListedWhenShown() throws {
        let mentions = [Mention(id: "3", username: "carol", url: nil, acct: "carol"), Mention(id: "4", username: "dave", url: nil, acct: "dave@remote.example")]
        let post = try status(url: nil, mentions: mentions)
        #expect(try !outline(menu(for: .status(post))).joined().contains("@carol[プロフィール,リンクをコピー,共有]"))

        let settings = try makeSettings()
        settings.statusMenuLayout = MenuLayout(elements: StatusMenuItem.defaultLayout.elements.map { element in
            element == .item(.mentionedUsers, isVisible: false) ? .item(.mentionedUsers, isVisible: true) : element
        })

        #expect(try outline(menu(for: .status(post), settings: settings)).last == ["@alice[プロフィール,リンクをコピー,共有]", "@carol[プロフィール,リンクをコピー,共有]", "@dave(remote.example)[プロフィール,リンクをコピー,共有]"])
    }
}
