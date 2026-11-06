import Foundation
import SciaCore
import Testing

/// 絵文字のリアクションのボタンのメニューの組み方を確かめる。決まりはdocs/emoji-reaction.mdの「リアクションのボタンのメニュー」にある。
@MainActor
struct ReactionMenuTreeTests {
    private let all = MenuLayout<ReactionMenuItem>(elements: ReactionMenuItem.allCases.map { .item($0, isVisible: true) } + [.more]).groups
    private let blobcat = ReactionEmoji(name: "blobcat", url: URL(string: "https://example.social/emoji/blobcat.png"))

    /// 見出しに絵文字と数を置き、付けていなければ「リアクションする」にする。画像のあるカスタム絵文字では「開く」を出す。
    @Test func customEmojiNotReacted() throws {
        let menu = try #require(ReactionMenuTree(reaction: EmojiReaction(emoji: blobcat, count: 1234, me: false)).menu(groups: all))

        #expect(menu.title == ":blobcat: \(1234.formatted())")
        #expect(MenuNodeTests.describe(menu.children) == "リアクションする,リアクションした人,開く,カスタマイズ")
        #expect(menu.children.first?.children.first?.command == .toggle(turningOn: true))
    }

    /// 自分がしたものは「リアクションを外す」にする。Unicodeの絵文字は画像がないので「開く」を出さない。
    @Test func unicodeEmojiReacted() throws {
        let menu = try #require(ReactionMenuTree(reaction: EmojiReaction(emoji: ReactionEmoji(name: "👍"), count: 2, me: true)).menu(groups: all))

        #expect(menu.title == "👍 2")
        #expect(MenuNodeTests.describe(menu.children) == "リアクションを外す,リアクションした人,カスタマイズ")
        #expect(menu.children.first?.children.first?.command == .toggle(turningOn: false))
    }

    /// 画像のURLを読めなかったカスタム絵文字は、見出しはショートコードで出し、「開く」は出さない。
    @Test func customEmojiWithoutImage() throws {
        let menu = try #require(ReactionMenuTree(reaction: EmojiReaction(emoji: ReactionEmoji(name: "broken_cat"), count: 1, me: false)).menu(groups: all))

        #expect(menu.title == ":broken_cat: 1")
        #expect(!MenuNodeTests.describe(menu.children).contains("開く"))
    }
}
