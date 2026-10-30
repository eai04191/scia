import Foundation
import SciaCore
import Testing

/// メディアのメニューを、設定の並びと、置く側が行えると言った項目から組むことを確かめる。決まりはdocs/menus.mdの「メディアのメニュー」にある。
@MainActor
struct MediaMenuTreeTests {
    private func attachment(_ type: MediaAttachment.Kind, description: String? = nil) -> MediaAttachment {
        MediaAttachment(
            id: "1",
            type: type,
            url: URL(string: "https://files.example.social/original/1.png"),
            previewUrl: nil,
            description: description,
            meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: 640, height: 480))
        )
    }

    /// 一覧で長押ししたときのように、すべての項目を行えるメニュー。
    private func timelineMenu(for attachment: MediaAttachment) -> MediaMenuTree {
        var menu = MediaMenuTree(kind: attachment.type, attachment: attachment)
        menu.open = true
        menu.share = true
        menu.saveToPhotos = true
        menu.showAltText = true
        menu.fileURL = attachment.url
        menu.linkBrowser = .external
        menu.statusMenu = [.action("返信", .status(.reply))]
        return menu
    }

    /// 既定の並びは、開く・共有・保存、読む、持ち出す、投稿の順にまとまりを分け、メディアの情報は「その他」に入れる。
    @Test func defaultMenuGroupsItemsByPurpose() {
        let nodes = timelineMenu(for: attachment(.image, description: "夕焼け")).nodes(groups: MediaMenuItem.defaultLayout.groups)

        #expect(MenuNodeTests.describe(nodes) == "開く,共有,写真に保存|代替テキスト|リンクをコピー,ブラウザで開く|投稿[返信]|その他[メディアの情報[640×480,PNG]]")
    }

    /// 写真に入らない音声では保存を、代替テキストのないメディアでは代替テキストを出さない。
    @Test func omitsItemsThatDoNotApply() {
        let described = MenuNodeTests.describe(timelineMenu(for: attachment(.audio)).nodes(groups: MediaMenuItem.defaultLayout.groups))

        #expect(!described.contains("写真に保存"))
        #expect(!described.contains("代替テキスト"))
        #expect(described.contains("共有"))
    }

    /// ビューアのように、開く項目と投稿のメニューがなければ、その項目を出さない。開く項目は、URLを扱えなければ出さない。押せない項目は押せないまま並べる。
    @Test func omitsItemsWithoutHandlers() {
        var menu = MediaMenuTree(kind: .image, attachment: attachment(.image))
        menu.share = false
        menu.saveToPhotos = false
        menu.fileURL = attachment(.image).url

        #expect(MenuNodeTests.describe(menu.nodes(groups: MediaMenuItem.defaultLayout.groups)) == "共有(押せない),写真に保存(押せない)|その他[メディアの情報[640×480,PNG]]")
    }

    /// 開く先のないビューア（Macの別のウィンドウや編集履歴から開いたとき）では、開く項目を出さず、リンクのコピーは残す。
    @Test func keepsCopyLinkWithoutOpeningURLs() {
        var menu = timelineMenu(for: attachment(.image))
        menu.opensURLs = false
        let described = MenuNodeTests.describe(menu.nodes(groups: MediaMenuItem.defaultLayout.groups))

        #expect(described.contains("リンクをコピー"))
        #expect(!described.contains("ブラウザで開く"))
    }

    /// 設定で隠した項目と、「その他」へ動かした項目は、その通りに出す。
    @Test func followsCustomizedLayout() {
        var elements = MediaMenuItem.defaultLayout.elements.compactMap { element -> MenuLayout<MediaMenuItem>.Element? in
            switch element {
            case .item(.open, _): .item(.open, isVisible: false)
            case .item(.share, _): nil
            default: element
            }
        }
        elements.append(.item(.share, isVisible: true))
        let described = MenuNodeTests.describe(timelineMenu(for: attachment(.image)).nodes(groups: MenuLayout(elements: elements).groups))

        #expect(described.hasPrefix("写真に保存|"))
        #expect(!described.contains("開く,"))
        #expect(described.hasSuffix("|その他[メディアの情報[640×480,PNG],共有]"))
    }

    /// メディアの情報の行は、値を名前に、何の値かをサブタイトルに置き、押すと値をコピーする。
    @Test func infoRowCopiesItsValue() throws {
        let nodes = timelineMenu(for: attachment(.image)).nodes(groups: MediaMenuItem.defaultLayout.groups)
        let info = try #require(nodes.last?.flattenedChildren.first)
        let resolution = try #require(info.children.first)

        #expect(resolution.title == "640×480")
        #expect(resolution.subtitle == "解像度")
        guard case .copyValue(let value) = resolution.command else {
            Issue.record("値をコピーする操作になっていません")
            return
        }
        #expect(value == "640×480")
    }

    /// カスタム絵文字は、`:shortcode:`のサブメニューにし、アイコンに絵文字の画像を置く。
    @Test func customEmojiSubmenu() throws {
        let url = try #require(URL(string: "https://example.social/emoji/blobcat.png"))
        let emoji = CustomEmoji(shortcode: "blobcat", url: url, staticUrl: url)
        var menu = MediaMenuTree(kind: .image, attachment: emoji.attachment)
        menu.open = true

        let node = try #require(menu.customEmojiSubmenu(emoji, groups: MediaMenuItem.defaultLayout.groups))
        #expect(MenuNodeTests.describe([node]) == ":blobcat:[開く,その他[メディアの情報[PNG]]]")
        #expect(node.icon?.symbolName == "face.smiling")
    }
}
