import Foundation
import SciaCore
import UIKit

/// 投稿のアクションバー（docs/post-action-bar.md）。タイムラインと同じく`TimelineViewController`の組み立てを通し、アクションバーの中身だけを状態ごとに渡す。
/// 引き出しの開閉の動き、ボタンを押したときの動き、件数が変わるところは、実物で確かめる。
enum PostActionBarCatalog {
    private typealias Fixtures = CatalogFixtures

    private static let author = Fixtures.account(displayName: "カタログのアカウント", acct: "catalog@example.com")
    private static let other = Fixtures.account(displayName: "ほかの人", acct: "other@example.com")

    private static let standardItems = PostActionBarItem.defaultLayout.actionBarItems

    @MainActor
    static func states() -> [CatalogState] {
        func post(
            _ title: String,
            items: [PostActionBarItem] = standardItems,
            showsCounts: Bool = true,
            favourited: Bool = false,
            reblogged: Bool = false,
            bookmarked: Bool = false,
            counts: (replies: Int, reblogs: Int, favourites: Int) = (0, 0, 0),
            spoilerText: String = "",
            reactions: [EmojiReaction] = [],
            unavailable: Set<StatusMenuItem> = []
        ) -> CatalogState {
            CatalogState(title: title) {
                let timeline = TimelineViewController(texts: .home, refresh: {})
                timeline.myAccountID = author.id
                timeline.supportsEmojiReactions = !reactions.isEmpty
                let status = Status(
                    id: UUID().uuidString,
                    createdAt: .now.addingTimeInterval(-3_600),
                    account: other,
                    content: "<p>アクションバーの付いた投稿。</p>",
                    spoilerText: spoilerText,
                    url: nil,
                    favourited: favourited,
                    reblogged: reblogged,
                    bookmarked: bookmarked,
                    favouritesCount: counts.favourites,
                    reblogsCount: counts.reblogs,
                    emojiReactions: reactions,
                    repliesCount: counts.replies
                )
                return CatalogFrame.post {
                    var configuration = timeline.contentConfiguration(for: status, base: .cell())
                    var bar = timeline.postContentBuilder.actionBar(for: status, countFont: configuration.metrics.timeFont) { !unavailable.contains($0) }
                    bar.buttons = PostActionBarButton.buttons(for: status, items: items, showsCounts: showsCounts) { !unavailable.contains($0) }
                    configuration.actionBar = bar
                    configuration.onActionBarPress = { _, _ in }
                    return configuration
                }
            }
        }
        return [
            post("既定の並び（件数なし）"),
            post("件数あり", counts: (3, 12, 45)),
            post("ブースト、お気に入り、ブックマークをした", favourited: true, reblogged: true, bookmarked: true, counts: (3, 12, 45)),
            post("大きい件数（1万からは万の単位で縮める）", counts: (9_999, 234_567, 1_234_567)),
            post("ボタンが8個で4桁の件数（小さくしても入らない件数は出さない）", items: [.status(.reply), .status(.reblog), .status(.favourite), .status(.bookmark), .status(.quote), .status(.share), .status(.copyLink), .menu], counts: (9_999, 8_888, 7_777)),
            post("件数を出さない設定", showsCounts: false, counts: (3, 12, 45)),
            post("押せない項目（薄く描く）", items: [.status(.reply), .status(.reblog), .status(.edit), .status(.delete), .menu], unavailable: [.reblog, .edit, .delete]),
            post("ボタンが多い", items: [.status(.reply), .status(.reblog), .status(.favourite), .status(.bookmark), .status(.quote), .status(.share), .status(.copyLink), .menu], counts: (1, 2, 3)),
            post("ボタンが1つ", items: [.menu]),
            post("絵文字のリアクションの列と重なる", counts: (1, 2, 3), reactions: [EmojiReaction(emoji: ReactionEmoji(name: "👍"), count: 2, me: true)]),
            post("注意書きで折りたたんでいても出す", counts: (1, 0, 5), spoilerText: "注意書き"),
        ]
    }
}
