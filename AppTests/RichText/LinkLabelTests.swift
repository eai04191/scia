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

    /// 行数を限って末尾を「…」で切る本文でも、2行目より後のリンクを、UILabelが描いた位置で押せる。ここでは「…」で切られる3行目のリンクを押す。
    /// UILabelは折り返してから最後の行だけを切るが、TextKit 2は「…」で切る段落を1行に並べるため、折り返して並べ直す。
    @Test func findsLinkInTruncatedParagraph() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let text = RichText(blocks: [
            .init(inlines: [
                .text("1行目の文章がここにありますので、続けて書いていきます。2行目にリンク ", []),
                .link("example.com/a", .url(url), []),
                .text(" があり、そのあとも長い文章がまだまだ続くので、最後の行は「…」で切られるはずです。", []),
            ]),
        ])
        // 折り返して並べたときの位置を、切らずに全部を描いたラベルで測る。
        let whole = label(for: text)
        let point = try center(of: "example.com/a", in: whole)
        let truncated = label(for: text)
        let attributed = NSMutableAttributedString(attributedString: try #require(truncated.attributedText))
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            attributed.addAttribute(.paragraphStyle, value: style, range: range)
        }
        truncated.numberOfLines = 3
        truncated.attributedText = attributed
        let size = truncated.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        truncated.frame = CGRect(origin: .zero, size: CGSize(width: 300, height: size.height))

        #expect(point.y > size.height * 2 / 3, "リンクは、見えている最後の行にある")
        #expect(truncated.link(at: point) == .url(url))
    }

    /// 「…」で切った最後の行で、「…」に置き換わって描かれていないリンクは、押しても当たりにしない。
    @Test func ignoresLinkReplacedByEllipsis() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        // 区切りのない長い英字は文字ごとに折り返すので、3行目の行末まで文字が詰まる。
        let text = RichText(blocks: [
            .init(inlines: [.text("1行目の文章です。", []), .link(String(repeating: "a", count: 300), .url(url), [])]),
        ])
        let whole = label(for: text)
        let truncated = truncatedLabel(text, lines: 3)
        // 切らずに描いたラベルで、3行目の行末の位置を測る。
        let layout = whole.textLayout(of: try #require(whole.attributedText))
        var lineEnds: [(minY: CGFloat, maxX: CGFloat)] = []
        layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                lineEnds.append((fragment.layoutFragmentFrame.minY + line.typographicBounds.minY, line.typographicBounds.maxX))
            }
            return true
        }
        let third = try #require(lineEnds.dropFirst(2).first)
        let ellipsisWidth = ("…" as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]).width
        #expect(third.maxX > truncated.bounds.width - ellipsisWidth, "3行目の行末の文字は「…」に置き換わる")
        let lineY = third.minY + 8
        let lineEnd = CGPoint(x: third.maxX - 1, y: lineY)

        #expect(whole.link(at: lineEnd) == .url(url), "切らなければ押せる位置")
        #expect(truncated.link(at: lineEnd) == nil)
        #expect(truncated.link(at: CGPoint(x: 20, y: lineY)) == .url(url), "「…」より前のリンクは押せる")
    }

    /// 最後の行に入りきらない単語のリンクも、UILabelは「…」の前まで途中を描くので、見えている部分を押せる。
    /// 段落を折り返しにして並べ直すと、単語ごと次の行に送られて、見えている部分が並ばない。
    @Test func findsPartlyShownLinkOnLastLine() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let prefix = "3行目にある長めの文章 "
        let text = RichText(blocks: [
            .init(inlines: [
                .text("1行目", []), .lineBreak, .text("2行目", []), .lineBreak,
                .text(prefix, []), .link("abcdefghijklmnopqrst", .url(url), []), .text(" そのあとの文章", []),
            ]),
        ])
        let truncated = truncatedLabel(text, lines: 3)
        let prefixWidth = (prefix as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]).width

        #expect(truncated.link(at: CGPoint(x: prefixWidth + 15, y: truncated.bounds.height - 8)) == .url(url))
    }

    /// 右から左に書く文字を含む段落でも、「…」で切った最後の行の、見えているリンクは押せる。
    @Test func findsLinkOnLastLineOfParagraphWithRightToLeftText() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let text = RichText(blocks: [
            .init(inlines: [
                .text("1行目", []), .lineBreak, .text("2行目", []), .lineBreak,
                .link("example", .url(url), []), .text(" の次に שלום עולם と書いた、とても長い文章がまだまだ続いていきます", []),
            ]),
        ])
        let truncated = truncatedLabel(text, lines: 3)

        #expect(truncated.link(at: CGPoint(x: 20, y: truncated.bounds.height - 8)) == .url(url))
    }

    /// `text`を、段落を末尾で「…」で切る設定にして、`lines`行に限ったラベル。
    private func truncatedLabel(_ text: RichText, lines: Int) -> LinkLabel {
        let label = label(for: text)
        let attributed = NSMutableAttributedString(attributedString: label.attributedText ?? NSAttributedString())
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            attributed.addAttribute(.paragraphStyle, value: style, range: range)
        }
        label.numberOfLines = lines
        label.attributedText = attributed
        let size = label.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(origin: .zero, size: CGSize(width: 300, height: size.height))
        return label
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

        #expect(try menuOutline(of: .url(url), settings: settings) == "https://example.com/a: ブラウザで開く,プロフィールとして開く,リンクをコピー,共有")
        #expect(try menuOutline(of: .hashtag(name: "cat", url: tag), settings: settings) == "#cat: ブラウザで開く,リンクをコピー,共有")
        #expect(try menuOutline(of: .mention(acct: "bob@example.social", url: profile), settings: settings) == "@bob@example.social: プロフィール|リンクをコピー,共有,ブラウザで開く")
    }

    /// 並べ替え、隠した項目、区切り線、「その他」の境目を、投稿のメニューと同じ決まりで反映する。
    @Test func menuFollowsCustomizedLayout() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let tag = try #require(URL(string: "https://example.social/tags/cat"))
        let settings = try settings()
        settings.linkMenuLayout = MenuLayout(elements: [.item(.share, isVisible: true), .separator, .item(.openInAppSafari, isVisible: true), .item(.openInBrowser, isVisible: false), .item(.openAsProfile, isVisible: false), .more, .item(.copyLink, isVisible: true)])
        settings.hashtagMenuLayout = MenuLayout(elements: [.item(.copyLink, isVisible: true), .item(.openInBrowser, isVisible: false), .item(.share, isVisible: false), .more])

        #expect(try menuOutline(of: .url(url), settings: settings) == "https://example.com/a: 共有|アプリ内のSafariで開く|その他[リンクをコピー]")
        #expect(try menuOutline(of: .hashtag(name: "cat", url: tag), settings: settings) == "#cat: リンクをコピー")
    }

    /// アプリ内のSafariはhttpとhttps以外のURLを開けず、サーバーもそのURLをプロフィールとして探さないため、そのリンクでは2つを押せない。ほかの開く項目は押せる。
    @Test func appSafariAndOpenAsProfileAreDisabledForNonWebLinks() throws {
        let magnet = try #require(URL(string: "magnet:?xt=urn:btih:0"))
        let web = try #require(URL(string: "https://example.com/a"))
        let settings = try settings()
        settings.linkMenuLayout = MenuLayout(elements: [.item(.openInBrowser, isVisible: true), .item(.openInDefaultBrowser, isVisible: true), .item(.openInAppSafari, isVisible: true), .item(.openAsProfile, isVisible: true), .more])

        #expect(try disabledTitles(of: .url(magnet), settings: settings) == ["アプリ内のSafariで開く", "プロフィールとして開く"])
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
