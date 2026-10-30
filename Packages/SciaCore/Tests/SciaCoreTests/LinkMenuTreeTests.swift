import Foundation
import SciaCore
import Testing

/// リンクのメニューと、ほかのサービスの投稿のメニューの組み方を確かめる。決まりはdocs/menus.mdにある。
@MainActor
struct LinkMenuTreeTests {
    private let all = MenuLayout<LinkMenuItem>(elements: LinkMenuItem.allCases.map { .item($0, isVisible: true) } + [.more]).groups

    /// 見出しにURLを置き、並びのとおりに出す。
    @Test func headingIsURL() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let menu = try #require(LinkMenuTree(url: url, linkBrowser: .inApp).menu(groups: all))

        #expect(menu.title == "https://example.com/a")
        #expect(MenuNodeTests.describe(menu.children) == "ブラウザで開く,既定のブラウザで開く,アプリ内のSafariで開く,プロフィールとして開く,リンクをコピー,共有")
    }

    /// httpとhttps以外のリンクでは、「プロフィールとして開く」とアプリ内のSafariで開くを押せない。
    @Test func nonWebLinkCannotOpenAsProfile() throws {
        let url = try #require(URL(string: "mailto:alice@example.com"))
        let menu = try #require(LinkMenuTree(url: url, linkBrowser: .inApp).menu(groups: all))

        #expect(MenuNodeTests.describe(menu.children) == "ブラウザで開く,既定のブラウザで開く,アプリ内のSafariで開く(押せない),プロフィールとして開く(押せない),リンクをコピー,共有")
    }

    /// 出す項目をすべて隠していれば、メニューを出さない。
    @Test func emptyLayoutHasNoMenu() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let hidden = MenuLayout<LinkMenuItem>(elements: LinkMenuItem.allCases.map { .item($0, isVisible: false) } + [.more]).groups

        #expect(LinkMenuTree(url: url, linkBrowser: .inApp).menu(groups: hidden) == nil)
    }

    /// ほかのサービスの投稿は、本文がなければ本文を使う項目を出さない。
    @Test func externalPostWithoutTextOmitsTextItems() throws {
        let url = try #require(URL(string: "https://x.com/alice/status/1"))
        let groups = MenuLayout<ExternalPostMenuItem>(elements: ExternalPostMenuItem.allCases.map { .item($0, isVisible: true) } + [.more]).groups

        let withText = try #require(ExternalPostMenuTree(url: url, text: "こんにちは", linkBrowser: .inApp).menu(groups: groups))
        let withoutText = try #require(ExternalPostMenuTree(url: url, text: nil, linkBrowser: .inApp).menu(groups: groups))

        #expect(withText.flattenedChildren.compactMap(\.command).contains(.copyText("こんにちは")))
        #expect(withText.flattenedChildren.compactMap(\.command).contains(.translate("こんにちは")))
        #expect(!withoutText.flattenedChildren.map(\.title).contains("テキストをコピー"))
        #expect(!withoutText.flattenedChildren.map(\.title).contains("翻訳"))
    }
}
