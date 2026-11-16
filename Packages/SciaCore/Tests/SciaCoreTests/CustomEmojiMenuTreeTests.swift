import Foundation
import SciaCore
import Testing

/// カスタム絵文字のメニューの組み方を確かめる。決まりはdocs/menus.mdの「カスタム絵文字のメニュー」にある。
@MainActor
struct CustomEmojiMenuTreeTests {
    private let original = URL(filePath: "/emoji/blobcat.gif")
    private let still = URL(filePath: "/emoji/static/blobcat.png")
    private var emoji: CustomEmoji { CustomEmoji(shortcode: "blobcat", url: original, staticUrl: still) }

    /// ほかのメニューに並べるときは、`:shortcode:`のサブメニューにし、アイコンに絵文字の画像を置く。置く側が行えると言った項目だけを出す。
    @Test func submenuListsWhatTheHostCanDo() throws {
        var tree = CustomEmojiMenuTree(emoji: emoji)
        tree.open = true

        let node = try #require(tree.submenu(groups: MenuFixture.customEmoji.groups))
        #expect(MenuNodeTests.describe([node]) == ":blobcat:[:blobcat:,開く,その他[メディアの情報[GIF],カスタマイズ]]")
        #expect(node.icon?.symbolName == "face.smiling")
    }

    /// コピーする文字は投稿に書ける`:shortcode:`の形にし、リンクはアニメーションしない版ではなく元の画像にする。
    @Test func copiesShortcodeWithColonsAndOriginalImage() throws {
        var tree = CustomEmojiMenuTree(emoji: emoji)
        tree.linkBrowser = .inApp
        tree.opensURLs = false
        let menu = tree.menu(groups: MenuFixture.customEmoji.groups)

        #expect(menu.title.isEmpty)
        #expect(MenuNodeTests.describe(menu.children) == ":blobcat:|リンクをコピー|その他[メディアの情報[GIF],カスタマイズ]")
        let commands = menu.children.flatMap(\.children).compactMap(\.command)
        guard case .copyShortcode(let text) = commands.first, case .url(.copy(let url)) = commands.last else {
            Issue.record("ショートコードのコピーとリンクのコピーが並んでいない")
            return
        }
        #expect(text == ":blobcat:")
        #expect(url == original)
    }
}
