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
        let mention = try #require(try mentionMenu(in: viewController, settings: settings))
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

    /// 一覧に載せた本文の、メンションのリンクを長押ししたときのメニュー。
    private func mentionMenu(in viewController: TimelineViewController, settings: AppSettings) throws -> UIMenu? {
        let url = try #require(alice.url)
        let destination = RichText.LinkDestination.mention(acct: alice.acct, url: url)
        let renderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: .offline, language: "ja")
        let label = LinkLabel()
        label.settings = settings
        label.attributedText = renderer.render(RichText(blocks: [.init(inlines: [.link("@alice", destination, [])])]))
        label.frame = CGRect(x: 0, y: 0, width: 300, height: 44)
        viewController.view.addSubview(label)
        let hitArea = try #require(label.subviews.compactMap { $0 as? LinkHitArea }.first)
        return hitArea.menu(for: destination, at: .zero)
    }
}
