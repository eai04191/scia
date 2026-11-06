#if DEBUG
import Foundation
import SciaCore
import UIKit

/// 投稿の絵文字のリアクションの列。一覧と同じく`TimelineViewController`の組み立てを通し、サーバーが対応している一覧として描く。
/// 付け外しの動きと失敗、ストリーミングで数が変わるところは、Fedibirdのアカウントと`scia-debug://dummy/reactions`の実物で確かめる。
enum EmojiReactionCatalog {
    private typealias Fixtures = CatalogFixtures

    private static let author = Fixtures.account(displayName: "カタログのアカウント", acct: "catalog@example.com")
    private static let other = Fixtures.account(displayName: "ほかの人", acct: "other@example.com")

    @MainActor
    static func states() -> [CatalogState] {
        let emojiURL = Fixtures.imageURL(width: 64, height: 64, color: .systemOrange)
        let local = ReactionEmoji(name: "square", url: emojiURL, staticUrl: emojiURL)
        let remote = ReactionEmoji(name: "remote_square", domain: "misskey.example", url: emojiURL, staticUrl: emojiURL)
        let many = ["👍", "🎉", "❤️", "😂", "🤔", "👀", "🙏", "🔥", "✨", "🥺", "🍣", "#️⃣", "🇯🇵", "👨‍👩‍👧‍👦"].enumerated().map { index, emoji in
            EmojiReaction(emoji: ReactionEmoji(name: emoji), count: index + 1, me: index == 2)
        }
        func post(_ title: String, _ reactions: [EmojiReaction], content: String = "<p>リアクションの付いた投稿。</p>", spoilerText: String = "", showsAddButton: Bool = true) -> CatalogState {
            CatalogState(title: title) {
                let timeline = TimelineViewController(texts: .home, refresh: {})
                timeline.myAccountID = author.id
                timeline.supportsEmojiReactions = true
                timeline.onToggleEmojiReaction = { _, _ in }
                if showsAddButton {
                    timeline.onAddEmojiReaction = { _ in }
                }
                let status = Status(
                    id: UUID().uuidString,
                    createdAt: .now.addingTimeInterval(-3_600),
                    account: other,
                    content: content,
                    spoilerText: spoilerText,
                    url: nil,
                    emojiReactions: reactions
                )
                return CatalogFrame.post { timeline.contentConfiguration(for: status, base: .cell()) }
            }
        }
        return [
            post("1つ", [EmojiReaction(emoji: ReactionEmoji(name: "👍"), count: 1, me: false)]),
            post("自分がしたもの", [EmojiReaction(emoji: ReactionEmoji(name: "👍"), count: 3, me: true), EmojiReaction(emoji: ReactionEmoji(name: "🎉"), count: 1, me: false)]),
            post("折り返すほど多い", many),
            post("このサーバーとほかのサーバーのカスタム絵文字", [EmojiReaction(emoji: local, count: 2, me: true), EmojiReaction(emoji: remote, count: 5, me: false)]),
            post("画像のURLが読めなかったカスタム絵文字（ショートコードを文字で出す）", [EmojiReaction(emoji: ReactionEmoji(name: "broken_emoji"), count: 1, me: false)]),
            post("数が大きい（桁区切り）", [EmojiReaction(emoji: ReactionEmoji(name: "🎉"), count: 12_345, me: true), EmojiReaction(emoji: ReactionEmoji(name: "👀"), count: 1_234_567, me: false)]),
            post("押す前の数が届いた自分のリアクション（0でも1と出す）", [EmojiReaction(emoji: ReactionEmoji(name: "👍"), count: 0, me: true)]),
            post("注意書きで折りたたんでいても出す", [EmojiReaction(emoji: ReactionEmoji(name: "🙈"), count: 2, me: false)], spoilerText: "注意書き"),
            post("「＋」のない列（プレビューなど、付けられない場所）", [EmojiReaction(emoji: ReactionEmoji(name: "👍"), count: 1, me: false)], showsAddButton: false),
        ]
    }
}
#endif
