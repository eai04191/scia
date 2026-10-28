import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 同じ対象のメニューを、出す場所によらず同じ見出し、中身、並びで組むことを確かめる。決まりはdocs/menus.mdの「メニューの単位」にある。
@Suite(.scratch)
@MainActor
struct MenuPlacementTests {
    private let alice = Account(id: "2", username: "alice", acct: "alice@remote.example", displayName: "Alice", avatar: nil, url: URL(string: "https://remote.example/@alice"))

    /// すべての項目を出し、区切り線と「その他」も使う並び。
    private func makeSettings() -> AppSettings {
        let settings = AppSettings(defaults: TestScratch.defaults("MenuPlacementTests"))
        let items = UserMenuItem.allCases.map { MenuLayout<UserMenuItem>.Element.item($0, isVisible: true) }
        settings.userMenuLayout = MenuLayout(elements: Array(items.prefix(3)) + [.separator] + Array(items.dropFirst(3).prefix(4)) + [.more] + Array(items.dropFirst(7)))
        return settings
    }

    /// 関係を覚えている相手として組ませ、関係の項目もその場で並べる。
    private func makeViewController(settings: AppSettings) -> TimelineViewController {
        let viewController = TimelineViewController(refresh: {}, tuning: TuningStore(defaults: nil), emojiImages: .offline, avatarImages: .offline, settings: settings)
        viewController.userMenuActions = UserMenuActions(
            mention: { _ in }, copyHandle: { _, _ in },
            resolveTarget: { _ in throw CancellationError() }, loadRelation: { _, _ in nil },
            knownRelation: { _ in .relation(UserRelation(accountID: "2", acct: "alice@remote.example", relationship: Relationship(id: "2", following: true))) },
            reloadRelations: { _ in },
            changeRelation: { _, _ in }, editNote: { _ in }, report: { _, _, _ in }, accounts: AccountCache { _ in [] }
        )
        return viewController
    }

    /// 項目の名前。いちばん上の区切り線のまとまりは`|`で、サブメニューは`名前[中身]`で表す。
    private func describe(_ elements: [UIMenuElement]) -> String {
        func describe(_ element: UIMenuElement) -> String {
            guard let menu = element as? UIMenu else { return element.title }
            let children = menu.children.map(describe).joined(separator: ",")
            return menu.options.contains(.displayInline) ? children : "\(menu.title)[\(children)]"
        }
        return elements.map(describe).joined(separator: "|")
    }

    /// 投稿のメニューのサブメニュー、行のアイコンの長押し、本文のメンションの長押しで、同じ見出し、項目、並びになる。
    /// プロフィール画面の「…」は、「プロフィール」を除いて同じになる。
    @Test func sameMenuFromEveryPlace() throws {
        let settings = makeSettings()
        let viewController = makeViewController(settings: settings)
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let post = Status(id: base.id, createdAt: base.createdAt, account: alice, content: base.content, spoilerText: "", url: nil)
        let entry = TimelineEntry.status(post)

        let submenu = try #require(viewController.contextMenu(for: entry, id: entry.id)?.children
            .flatMap { ($0 as? UIMenu)?.children ?? [] }
            .compactMap { $0 as? UIMenu }
            .first { $0.title == "@alice" })
        let avatar = try #require(viewController.userMenu(for: .account(alice), id: entry.id))
        let profileURL = try #require(alice.url)
        let mention = try #require(try bodyLinkMenu(for: .mention(acct: alice.acct, url: profileURL), in: viewController, settings: settings))
        let profile = try #require(viewController.profileUserMenu(for: alice, from: UIBarButtonItem()))

        let expected = "プロフィール,メンション,ハンドルをコピー|リンクをコピー,共有,ブラウザで開く,既定のブラウザで開く|その他[アプリ内のSafariで開く,フォローを外す,ブーストを表示,投稿を通知,メモを追加,ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日],ブロック,通報]"
        #expect(describe(submenu.children) == expected)
        #expect(describe(avatar.children) == expected)
        #expect(describe(mention.children) == expected)
        #expect(describe(profile.children) == "メンション,ハンドルをコピー|リンクをコピー,共有,ブラウザで開く,既定のブラウザで開く|その他[アプリ内のSafariで開く,フォローを外す,ブーストを表示,投稿を通知,メモを追加,ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日],ブロック,通報]")
        // 見出しは、サブメニューでは名前とサブタイトル、単独で出すメニューでは2行に置く。
        #expect(submenu.title == "@alice")
        #expect(submenu.subtitle == "remote.example")
        #expect(avatar.title == "@alice\nremote.example")
        #expect(mention.title == avatar.title)
    }

    /// 本文のリンクの長押しと、リンクカードの長押しで、同じ見出し、項目、並びになる。
    @Test func sameLinkMenuFromBodyAndCard() throws {
        let settings = makeSettings()
        let items = LinkMenuItem.allCases.map { MenuLayout<LinkMenuItem>.Element.item($0, isVisible: true) }
        settings.linkMenuLayout = MenuLayout(elements: Array(items.prefix(2)) + [.separator] + Array(items.dropFirst(2).prefix(2)) + [.more] + Array(items.dropFirst(4)))
        let viewController = makeViewController(settings: settings)
        let url = try #require(URL(string: "https://example.com/a"))
        let entry = try #require(StatusFactory.make(count: 1, startingAt: 100).first.map(TimelineEntry.status))

        let body = try #require(try bodyLinkMenu(for: .url(url), in: viewController, settings: settings))
        let card = try #require(viewController.linkMenu(for: url, id: entry.id))

        let expected = "ブラウザで開く,既定のブラウザで開く|アプリ内のSafariで開く,プロフィールとして開く|その他[リンクをコピー,共有]"
        #expect(describe(body.children) == expected)
        #expect(describe(card.children) == expected)
        #expect(body.title == "https://example.com/a")
        #expect(card.title == body.title)
    }

    /// 本文のハッシュタグの長押しと、投稿のメニューの「ハッシュタグ」で、同じ見出し、項目、並びになる。
    /// 投稿のメニューでは、サブメニューの項目に「ハッシュタグ」のアイコンを付ける。
    @Test func sameHashtagMenuFromBodyAndStatusMenu() throws {
        let settings = makeSettings()
        let items = HashtagMenuItem.allCases.map { MenuLayout<HashtagMenuItem>.Element.item($0, isVisible: true) }
        settings.hashtagMenuLayout = MenuLayout(elements: Array(items.prefix(3)) + [.separator] + Array(items.dropFirst(3).prefix(2)) + [.more] + Array(items.dropFirst(5)))
        let viewController = makeViewController(settings: settings)
        viewController.hashtagMuteActions = HashtagMuteActions(known: { _ in false }, refresh: {}, load: { _ in false }, mute: { _, _ in }, unmute: { _ in })
        let tagURL = try #require(URL(string: "https://example.social/tags/cat"))
        let base = try #require(StatusFactory.make(count: 1, startingAt: 100).first)
        let post = Status(id: base.id, createdAt: base.createdAt, account: alice, content: base.content, spoilerText: "", url: nil, tags: [Tag(name: "cat", url: tagURL)])
        let entry = TimelineEntry.status(post)

        let body = try #require(try bodyLinkMenu(for: .hashtag(name: "cat", url: tagURL), in: viewController, settings: settings, hashtagAccount: alice))
        let submenu = try #require(viewController.contextMenu(for: entry, id: entry.id)?.children
            .flatMap { ($0 as? UIMenu)?.children ?? [] }
            .compactMap { $0 as? UIMenu }
            .first { $0.title == "#cat" })

        let expected = "すべての投稿,@aliceの投稿,ミュート[無期限,5分,30分,1時間,6時間,1日,3日,7日]|ブラウザで開く,既定のブラウザで開く|その他[アプリ内のSafariで開く,リンクをコピー,共有]"
        #expect(describe(body.children) == expected)
        #expect(describe(submenu.children) == expected)
        #expect(body.title == "#cat")
        #expect(submenu.image != nil)
    }

    /// 一覧に載せた本文の、リンクを長押ししたときのメニュー。
    /// - Parameter hashtagAccount: ハッシュタグのメニューの「投稿したユーザーの投稿」で開くユーザー。
    private func bodyLinkMenu(for destination: RichText.LinkDestination, in viewController: TimelineViewController, settings: AppSettings, hashtagAccount: Account? = nil) throws -> UIMenu? {
        let renderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: .offline, language: "ja")
        let label = LinkLabel()
        label.settings = settings
        label.hashtagAccount = hashtagAccount
        label.attributedText = renderer.render(RichText(blocks: [.init(inlines: [.link("x", destination, [])])]))
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 44)
        viewController.view.addSubview(label)
        let hitArea = try #require(label.subviews.compactMap { $0 as? LinkHitArea }.first)
        return hitArea.menu(for: destination, at: .zero)
    }
}
