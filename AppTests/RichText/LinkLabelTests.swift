import Foundation
import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct LinkLabelTests {
    private func label(for text: RichText, width: CGFloat = 300) -> LinkLabel {
        let renderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: .offline, language: "ja")
        let label = LinkLabel()
        label.numberOfLines = 0
        label.attributedText = renderer.render(text)
        let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        label.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        return label
    }

    /// 文字列`substring`の、描いた位置の中央。
    private func center(of substring: String, in label: LinkLabel) throws -> CGPoint {
        let attributed = try #require(label.attributedText)
        let range = (attributed.string as NSString).range(of: substring)
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    @Test func findsLinkUnderPoint() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let profile = try #require(URL(string: "https://example.social/@bob"))
        let text = RichText(blocks: [
            .init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), []), .text(" と ", []), .link("@bob", .mention(acct: "bob@example.social", url: profile), [])]),
        ])
        let label = label(for: text)

        #expect(label.link(at: try center(of: "example.com/a", in: label)) == .url(url))
        #expect(label.link(at: try center(of: "@bob", in: label)) == .mention(acct: "bob@example.social", url: profile))
        #expect(label.link(at: try center(of: "見て", in: label)) == nil)
    }

    /// 行末より右を押しても、近くのリンクを押したことにしない。
    @Test func ignoresPointPastLineEnd() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let text = RichText(blocks: [.init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), [])])])
        let label = label(for: text)
        let link = try center(of: "example.com/a", in: label)

        #expect(label.link(at: CGPoint(x: label.bounds.maxX - 1, y: link.y)) == nil)
    }

    /// MacのDesigned for iPadでは、アクティブでないウィンドウへの最初のクリックを、押された場所のビューが`UIControl`のときだけ通す。
    /// リンクの上では`UIControl`に当たり、リンクの外ではラベルに当たらず、後ろのビュー（セルや、Xの投稿の囲みのボタン）へ渡ることを確かめる。
    @Test func hitsControlOnlyOverLink() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let text = RichText(blocks: [.init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), [])])])
        let label = label(for: text)

        let onLink = label.hitTest(try center(of: "example.com/a", in: label), with: nil)
        #expect(onLink is UIControl)
        #expect(onLink !== label)
        #expect(label.hitTest(try center(of: "見て", in: label), with: nil) == nil)
    }

    /// 文字列や幅が変わったら、前に並べた結果を使わずに並べ直す。
    @Test func relayoutsAfterTextOrWidthChange() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let label = label(for: RichText(blocks: [.init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), [])])]))
        let link = try center(of: "example.com/a", in: label)
        #expect(label.link(at: link) == .url(url))

        let renderer = RichTextRenderer(font: .preferredFont(forTextStyle: .body), textColor: .label, emojiImages: .offline, language: "ja")
        label.attributedText = renderer.render(RichText(blocks: [.init(inlines: [.text("リンクのない本文です。リンクのない本文です。", [])])]))
        #expect(label.link(at: link) == nil)

        // 幅を狭めて、リンクを3行目より下へ折り返させる。
        label.attributedText = renderer.render(RichText(blocks: [.init(inlines: [.text("見て見て見て見て見て見て見て見て ", []), .link("abc", .url(url), [])])]))
        #expect(label.link(at: try center(of: "abc", in: label)) == .url(url))
        let narrow = label.sizeThatFits(CGSize(width: 60, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(origin: .zero, size: CGSize(width: 60, height: narrow.height))
        let wrapped = try center(of: "abc", in: label)
        #expect(label.link(at: wrapped) == .url(url))
    }

    /// リンクを押して少し止めてから引いても、タイムラインと編集履歴はスクロールに切り替える。
    @Test func scrollViewsCancelLinkTouches() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let label = label(for: RichText(blocks: [.init(inlines: [.text("見て ", []), .link("example.com/a", .url(url), [])])]))
        let hitArea = try #require(label.hitTest(try center(of: "example.com/a", in: label), with: nil))

        #expect(TimelineCollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout()).touchesShouldCancel(in: hitArea))
        #expect(EditHistoryScrollView().touchesShouldCancel(in: hitArea))
        #expect(!UIScrollView().touchesShouldCancel(in: hitArea))
    }

    private func settings() throws -> AppSettings {
        let suite = "LinkLabelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    /// 本文のリンクの長押しのメニューの、見出しと項目の名前。区切り線のまとまりは`|`で、サブメニューは`名前[中身]`で表す。
    private func menuOutline(of destination: RichText.LinkDestination, settings: AppSettings) throws -> String? {
        let label = label(for: RichText(blocks: [.init(inlines: [.link("x", destination, [])])]))
        label.settings = settings
        let hitArea = try #require(label.subviews.compactMap { $0 as? LinkHitArea }.first)
        guard let menu = hitArea.menu(for: destination, at: .zero) else { return nil }
        func describe(_ element: UIMenuElement) -> String {
            guard let menu = element as? UIMenu else { return element.title }
            let children = menu.children.map(describe).joined(separator: ",")
            return menu.options.contains(.displayInline) ? children : "\(menu.title)[\(children)]"
        }
        return "\(menu.title): " + menu.children.map(describe).joined(separator: "|")
    }

    /// URL、ハッシュタグ、メンションは、それぞれリンクのメニュー、ハッシュタグのメニュー、ユーザーのメニューの既定の並びで出す。
    @Test func menuFollowsDefaultLayoutOfEachKind() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let tag = try #require(URL(string: "https://example.social/tags/cat"))
        let profile = try #require(URL(string: "https://example.social/@bob"))
        let settings = try settings()

        #expect(try menuOutline(of: .url(url), settings: settings) == "https://example.com/a: ブラウザで開く,リンクをコピー,共有")
        #expect(try menuOutline(of: .hashtag(name: "cat", url: tag), settings: settings) == "#cat: ブラウザで開く,リンクをコピー,共有")
        #expect(try menuOutline(of: .mention(acct: "bob@example.social", url: profile), settings: settings) == "@bob@example.social: プロフィール,リンクをコピー,共有")
    }

    /// 並べ替え、隠した項目、区切り線、「その他」の境目を、投稿のメニューと同じ決まりで反映する。
    @Test func menuFollowsCustomizedLayout() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let tag = try #require(URL(string: "https://example.social/tags/cat"))
        let settings = try settings()
        settings.linkMenuLayout = MenuLayout(elements: [.item(.share, isVisible: true), .separator, .item(.openInAppSafari, isVisible: true), .item(.openInBrowser, isVisible: false), .more, .item(.copyLink, isVisible: true)])
        settings.hashtagMenuLayout = MenuLayout(elements: [.item(.copyLink, isVisible: true), .item(.openInBrowser, isVisible: false), .item(.share, isVisible: false), .more])

        #expect(try menuOutline(of: .url(url), settings: settings) == "https://example.com/a: 共有|アプリ内のSafariで開く|その他[リンクをコピー]")
        #expect(try menuOutline(of: .hashtag(name: "cat", url: tag), settings: settings) == "#cat: リンクをコピー")
    }

    /// アプリ内のSafariはhttpとhttps以外のURLを開けないため、そのリンクでは押せない。ほかの開く項目は押せる。
    @Test func appSafariIsDisabledForNonWebLinks() throws {
        let magnet = try #require(URL(string: "magnet:?xt=urn:btih:0"))
        let web = try #require(URL(string: "https://example.com/a"))
        let settings = try settings()
        settings.linkMenuLayout = MenuLayout(elements: [.item(.openInBrowser, isVisible: true), .item(.openInDefaultBrowser, isVisible: true), .item(.openInAppSafari, isVisible: true), .more])

        #expect(try disabledTitles(of: .url(magnet), settings: settings) == ["アプリ内のSafariで開く"])
        #expect(try disabledTitles(of: .url(web), settings: settings).isEmpty)
    }

    private func disabledTitles(of destination: RichText.LinkDestination, settings: AppSettings) throws -> [String] {
        let label = label(for: RichText(blocks: [.init(inlines: [.link("x", destination, [])])]))
        label.settings = settings
        let hitArea = try #require(label.subviews.compactMap { $0 as? LinkHitArea }.first)
        let menu = try #require(hitArea.menu(for: destination, at: .zero))
        func actions(_ element: UIMenuElement) -> [UIAction] {
            (element as? UIAction).map { [$0] } ?? (element as? UIMenu)?.children.flatMap(actions) ?? []
        }
        return actions(menu).filter { $0.attributes.contains(.disabled) }.map(\.title)
    }

    /// 開く項目は、ブラウザで開くだけが開く場所の設定に従い、ほかの2つは設定にかかわらず選んだ場所で開く。
    /// 設定がアプリ内のSafariでも、httpとhttps以外のURLは既定のブラウザで開く（開く場所の設定の決まり）。
    @Test func openItemsChooseBrowser() throws {
        let web = try #require(URL(string: "https://example.com/a"))
        let magnet = try #require(URL(string: "magnet:?xt=urn:btih:0"))

        #expect(URLMenuAction.openInBrowser.browser(for: web, following: .inApp) == .inApp)
        #expect(URLMenuAction.openInBrowser.browser(for: web, following: .external) == .external)
        #expect(URLMenuAction.openInBrowser.browser(for: magnet, following: .inApp) == .external)
        #expect(URLMenuAction.openInDefaultBrowser.browser(for: web, following: .inApp) == .external)
        #expect(URLMenuAction.openInAppSafari.browser(for: web, following: .external) == .inApp)
        #expect(URLMenuAction.openInAppSafari.browser(for: magnet, following: .inApp) == nil)
    }

    /// 出す項目をすべて隠したら、メニューを出さない。
    @Test func hidingEveryItemShowsNoMenu() throws {
        let tag = try #require(URL(string: "https://example.social/tags/cat"))
        let settings = try settings()
        settings.hashtagMenuLayout = MenuLayout(elements: [.item(.openInBrowser, isVisible: false), .item(.copyLink, isVisible: false), .item(.share, isVisible: false), .more])

        #expect(try menuOutline(of: .hashtag(name: "cat", url: tag), settings: settings) == nil)
    }
}
