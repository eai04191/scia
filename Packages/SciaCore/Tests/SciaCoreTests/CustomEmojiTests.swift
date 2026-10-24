import Foundation
import Testing
@testable import SciaCore

struct CustomEmojiTests {
    private func emoji(_ shortcode: String, host: String = "example.com") -> CustomEmoji {
        CustomEmoji(
            shortcode: shortcode,
            url: URL(string: "https://\(host)/emoji/\(shortcode).gif") ?? URL(fileURLWithPath: "/"),
            staticUrl: URL(string: "https://\(host)/emoji/\(shortcode).png") ?? URL(fileURLWithPath: "/")
        )
    }

    private func status(id: String, account: Account, emojis: [CustomEmoji] = [], reblog: Status? = nil) -> Status {
        Status(id: id, createdAt: Date(timeIntervalSince1970: 0), account: account, content: "", spoilerText: "", url: nil, emojis: emojis, reblog: reblog)
    }

    /// 表示名には、渡した絵文字をすべて`:shortcode:`で書く。
    private func account(id: String, emojis: [CustomEmoji] = []) -> Account {
        let displayName = emojis.map { ":\($0.shortcode):" }.joined(separator: " ")
        return Account(id: id, username: "u\(id)", acct: "u\(id)", displayName: displayName, avatar: nil, emojis: emojis)
    }

    @Test func attachmentUsesOriginalImageAndStillImageAsPreview() {
        let attachment = emoji("blobcat").attachment

        #expect(attachment.type == .image)
        #expect(attachment.url == emoji("blobcat").url)
        #expect(attachment.previewUrl == emoji("blobcat").staticUrl)
    }

    /// サーバーが違えば、同じショートコードでも別の絵文字として扱う。
    @Test func attachmentIDsDifferBetweenServers() {
        #expect(emoji("blobcat").attachment.id != emoji("blobcat", host: "other.example").attachment.id)
    }

    /// アカウントの絵文字には自己紹介や補足情報の絵文字も入るため、行に出ない絵文字を除き、表示名で使っているものだけを出す。
    @Test func accountEmojisAreLimitedToDisplayName() {
        let author = Account(
            id: "1", username: "alice", acct: "alice", displayName: "Alice :name:", avatar: nil,
            note: "<p>:bio:</p>", fields: [Account.Field(name: ":field:", value: ":field:")], emojis: [emoji("bio"), emoji("name"), emoji("field")]
        )
        let booster = Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: nil, note: "<p>:bio:</p>", emojis: [emoji("bio")])
        let post = status(id: "1", account: author)

        #expect(post.emojisInRow.map(\.shortcode) == ["name"])
        #expect(status(id: "2", account: booster, reblog: post).emojisInRow.map(\.shortcode) == ["name"])
        let favourite = MastodonNotification(id: "1", type: .favourite, createdAt: Date(timeIntervalSince1970: 0), account: booster, status: post)
        #expect(favourite.emojisInRow.map(\.shortcode) == ["name"])
    }

    @Test func emojisInRowListStatusEmojisThenAuthorEmojisWithoutDuplicates() {
        let status = status(
            id: "1",
            account: account(id: "1", emojis: [emoji("name"), emoji("shared")]),
            emojis: [emoji("body"), emoji("shared")]
        )

        #expect(status.emojisInRow.map(\.shortcode) == ["body", "shared", "name"])
    }

    /// ブーストでは、元の投稿と元の投稿者の絵文字に、行に名前を出すブーストした人の絵文字を続ける。
    @Test func emojisInRowOfReblogFollowOriginalWithBooster() {
        let original = status(id: "1", account: account(id: "1", emojis: [emoji("author")]), emojis: [emoji("body")])
        let reblog = status(id: "2", account: account(id: "2", emojis: [emoji("booster")]), reblog: original)

        #expect(reblog.emojisInRow.map(\.shortcode) == ["body", "author", "booster"])
    }

    /// 通知では、対象の投稿の絵文字に、通知した人の絵文字を続ける。投稿のない通知では、通知した人の絵文字だけ。
    @Test func emojisInRowOfNotificationFollowStatusWithNotifyingUser() {
        let post = status(id: "1", account: account(id: "1"), emojis: [emoji("body")])
        let favourite = MastodonNotification(id: "1", type: .favourite, createdAt: Date(timeIntervalSince1970: 0), account: account(id: "2", emojis: [emoji("fan")]), status: post)
        let follow = MastodonNotification(id: "2", type: .follow, createdAt: Date(timeIntervalSince1970: 0), account: account(id: "2", emojis: [emoji("fan")]))

        #expect(favourite.emojisInRow.map(\.shortcode) == ["body", "fan"])
        #expect(follow.emojisInRow.map(\.shortcode) == ["fan"])
    }
}
