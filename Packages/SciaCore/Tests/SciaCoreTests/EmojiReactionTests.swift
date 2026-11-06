import Foundation
import Testing
@testable import SciaCore

struct EmojiReactionTests {
    private let thumbsUp = ReactionEmoji(name: "👍")
    private let localBlobcat = ReactionEmoji(name: "blobcat", url: URL(string: "https://fedibird.example/emoji/blobcat.png"))
    private let remoteCat = ReactionEmoji(name: "remote_cat", domain: "misskey.example", url: URL(string: "https://fedibird.example/cache/blobcat.png"))

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func status(_ reactions: [EmojiReaction] = []) -> Status {
        Status(
            id: "10",
            createdAt: Date(timeIntervalSince1970: 0),
            account: Account(id: "2", username: "bob", acct: "bob", displayName: "Bob", avatar: URL(string: "https://example.social/a.png")),
            content: "<p>本文</p>",
            spoilerText: "",
            url: nil,
            emojiReactions: reactions
        )
    }

    /// リアクションだけが変わった投稿を見分ける。ブーストでは元の投稿のリアクションを比べ、ほかも変わっていれば当たらない。
    @Test func detectsReactionOnlyChange() {
        let before = status([EmojiReaction(emoji: thumbsUp, count: 1, me: false)])
        let after = before.settingEmojiReaction(thumbsUp, true)
        #expect(after.differsOnlyInEmojiReactions(from: before))
        #expect(!before.differsOnlyInEmojiReactions(from: before))
        #expect(!after.settingFavourited(true).differsOnlyInEmojiReactions(from: before))

        let boost = Status(id: "11", createdAt: Date(timeIntervalSince1970: 0), account: before.account, content: "", spoilerText: "", url: nil, reblog: before)
        #expect(boost.replacingReblog(with: after).differsOnlyInEmojiReactions(from: boost))
    }

    /// Fedibirdの形を読む。ほかのサーバーのカスタム絵文字は、そのサーバーを`domain`に持つ。
    /// 読み込む画像として受け付けないURLは、画像なしの絵文字として読み、名前のないものは除く。
    @Test func decodesFedibirdReactions() throws {
        let status = try MastodonDecoder.make().decode(Status.self, from: fixture("fedibird_status_emoji_reactions"))

        #expect(status.emojiReactions.map(\.emoji.name) == ["👍", "blobcat", "remote_cat", "broken"])
        #expect(status.emojiReactions.map(\.emoji.domain) == [nil, nil, "misskey.example", nil])
        #expect(status.emojiReactions.map(\.count) == [3, 1, 2, 1])
        #expect(status.emojiReactions.map(\.me) == [true, false, false, false])
        #expect(status.emojiReactions[2].emoji.customEmoji?.staticUrl == URL(string: "https://fedibird.example/cache/blobcat.webp"))
        #expect(status.emojiReactions[3].emoji.url == nil)
    }

    @Test func statusWithoutReactionsHasNone() throws {
        #expect(status().emojiReactions.isEmpty)
    }

    /// ほかのサーバーのカスタム絵文字は、Fedibirdが`name@domain`で受け取る。
    @Test func requestNameIncludesDomainOfRemoteEmoji() {
        #expect(thumbsUp.requestName == "👍")
        #expect(localBlobcat.requestName == "blobcat")
        #expect(remoteCat.requestName == "remote_cat@misskey.example")
    }

    /// Fedibirdは名前でまとめるので、同じ絵文字かは名前だけで見分ける。画像のURLとサーバーは比べない。
    @Test func sameEmojiIsDecidedByName() {
        #expect(localBlobcat == ReactionEmoji(name: "blobcat", url: URL(string: "https://fedibird.example/other.png")))
        #expect(localBlobcat == ReactionEmoji(name: "blobcat", domain: "misskey.example"))
        #expect(localBlobcat != remoteCat)
    }

    /// 最後のリアクションが消えたときのイベントには、`domain`と画像が入らない。名前で見分けて消す。
    @Test func zeroCountEventWithoutDomainRemovesRemoteReaction() throws {
        let shown = status([EmojiReaction(emoji: remoteCat, count: 1, me: false)])
        let json = #"{"name":"remote_cat","count":0,"account_ids":[],"status_id":"10"}"#
        let update = try MastodonDecoder.make().decode(EmojiReactionUpdate.self, from: Data(json.utf8))

        #expect(shown.applyingEmojiReactionUpdate(update, me: false).emojiReactions.isEmpty)
    }

    /// 付けるとき、まだない絵文字は末尾に足し、ある絵文字は数を増やす。外して0になれば消す。
    @Test func settingReactionAddsCountsAndRemoves() {
        let start = status([EmojiReaction(emoji: thumbsUp, count: 2, me: false)])

        let added = start.settingEmojiReaction(thumbsUp, true).settingEmojiReaction(localBlobcat, true)
        #expect(added.emojiReactions.map(\.emoji) == [thumbsUp, localBlobcat])
        #expect(added.emojiReactions.map(\.count) == [3, 1])
        #expect(added.emojiReactions.map(\.me) == [true, true])

        let removed = added.settingEmojiReaction(localBlobcat, false).settingEmojiReaction(thumbsUp, false)
        #expect(removed.emojiReactions.map(\.count) == [2])
        #expect(removed.emojiReactions.map(\.me) == [false])
    }

    /// 応答からは、送った絵文字の分だけを取り込む。待っている間に押したほかの絵文字の見込みを戻さないため。
    @Test func adoptingTakesOnlyThatEmoji() {
        let shown = status([EmojiReaction(emoji: thumbsUp, count: 1, me: true), EmojiReaction(emoji: localBlobcat, count: 1, me: true)])
        let response = status([EmojiReaction(emoji: thumbsUp, count: 4, me: true)])

        let adopted = shown.adoptingEmojiReaction(thumbsUp, of: response)
        #expect(adopted.emojiReactions.map(\.count) == [4, 1])
        #expect(adopted.emojiReactions.map(\.me) == [true, true])

        let gone = shown.adoptingEmojiReaction(localBlobcat, of: response)
        #expect(gone.emojiReactions.map(\.emoji) == [thumbsUp])
    }

    /// ストリーミングの数は届いた値に置き換え、0で自分もしていなければ消し、ない絵文字は末尾に足す。
    @Test func streamingUpdateReplacesCount() {
        let shown = status([EmojiReaction(emoji: thumbsUp, count: 1, me: false), EmojiReaction(emoji: localBlobcat, count: 1, me: true)])

        let counted = shown.applyingEmojiReactionUpdate(EmojiReactionUpdate(statusID: "10", emoji: thumbsUp, count: 5, accountIDs: []), me: false)
        #expect(counted.emojiReactions.map(\.count) == [5, 1])

        let removed = shown.applyingEmojiReactionUpdate(EmojiReactionUpdate(statusID: "10", emoji: thumbsUp, count: 0, accountIDs: []), me: false)
        #expect(removed.emojiReactions.map(\.emoji) == [localBlobcat])

        let appended = shown.applyingEmojiReactionUpdate(EmojiReactionUpdate(statusID: "10", emoji: remoteCat, count: 2, accountIDs: []), me: false)
        #expect(appended.emojiReactions.map(\.emoji) == [thumbsUp, localBlobcat, remoteCat])
    }

    /// 押した結果より先に押す前の数（0）が届いても、自分がしているなら残し、1と出す。
    @Test func streamingZeroKeepsOwnReaction() {
        let shown = status([EmojiReaction(emoji: localBlobcat, count: 1, me: true)])

        let updated = shown.applyingEmojiReactionUpdate(EmojiReactionUpdate(statusID: "10", emoji: localBlobcat, count: 0, accountIDs: []), me: true)
        #expect(updated.emojiReactions.map(\.displayedCount) == [1])
    }

    /// ストリーミングの中身を読む。Fedibirdは、数のほかに、リアクションした人のIDと、カスタム絵文字なら画像とサーバーを入れる。
    @Test func decodesStreamingPayload() throws {
        let json = #"{"name":"remote_cat","count":2,"url":"https://fedibird.example/cache/blobcat.png","static_url":"https://fedibird.example/cache/blobcat.webp","domain":"misskey.example","account_ids":["5","6"],"status_id":"10"}"#
        let update = try MastodonDecoder.make().decode(EmojiReactionUpdate.self, from: Data(json.utf8))

        #expect(update.statusID == "10")
        #expect(update.emoji == remoteCat)
        #expect(update.count == 2)
        #expect(update.accountIDs == ["5", "6"])
    }

    /// デバッグのダミーのサーバーと同じく、APIの形（snake_case）に書き出しても、読み直せる。
    @Test func roundTripsThroughEncoding() throws {
        let original = status([EmojiReaction(emoji: remoteCat, count: 2, me: true)])
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try MastodonDecoder.make().decode(Status.self, from: encoder.encode(original))

        #expect(decoded.emojiReactions == original.emojiReactions)
        #expect(decoded.emojiReactions.first?.emoji.url == remoteCat.url)
    }

    /// Fedibirdのv1の通知は、付けた絵文字を`emoji_reaction`に入れる。まとめない種類なので、1件ずつの行になる。
    @Test func decodesReactionNotification() throws {
        let status = try #require(JSONSerialization.jsonObject(with: fixture("fedibird_status_emoji_reactions")) as? [String: Any])
        let object: [String: Any] = [
            "id": "50",
            "type": "emoji_reaction",
            "created_at": "2026-11-05T12:00:00.000Z",
            "account": try #require(status["account"]),
            "status": status,
            "emoji_reaction": [
                "name": "remote_cat", "count": 0, "me": false, "domain": "misskey.example",
                "url": "https://fedibird.example/cache/blobcat.png", "static_url": "https://fedibird.example/cache/blobcat.webp",
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: object)
        let notification = try MastodonDecoder.make().decode(MastodonNotification.self, from: json)

        #expect(notification.type == .emojiReaction)
        #expect(notification.reactionEmoji == remoteCat)
        #expect(notification.groupKey == "ungrouped-50")
        #expect(notification.layout == .quoted(showsPollResults: false))
    }
}
