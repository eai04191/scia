import Foundation
import Testing
@testable import SciaCore

/// 投票、リンクカード、一致したフィルター、編集した日時、ブックマークを読めることと、それらが壊れていても投稿は読めることを確かめる。
struct StatusExtrasDecodingTests {
    @Test func decodesPollCardFilterEditAndBookmark() throws {
        let status = try decodeFixture("status_with_poll_and_card")

        let poll = try #require(status.poll)
        #expect(poll.id == "34830")
        #expect(poll.expiresAt == Date(timeIntervalSince1970: 1_791_948_105))
        #expect(!poll.expired)
        #expect(poll.multiple)
        #expect(poll.votesCount == 10)
        #expect(poll.votersCount == 6)
        #expect(poll.options.map(\.title) == ["りんご :apple:", "みかん", "ぶどう"])
        #expect(poll.options.map(\.votesCount) == [5, 3, 2])
        #expect(poll.emojis.map(\.shortcode) == ["apple"])
        #expect(poll.voted)
        #expect(poll.ownVotes == [0, 2])

        let card = try #require(status.card)
        #expect(card.url.absoluteString == "https://news.example/articles/1")
        #expect(card.title == "記事の見出し")
        #expect(card.description == "記事の要約")
        #expect(card.type == .link)
        #expect(card.authorName == "記者")
        #expect(card.providerName == "News Example")
        #expect(card.image?.absoluteString == "https://example.social/cache/preview_cards/images/1.jpeg")
        #expect(card.width == 400)
        #expect(card.height == 225)
        #expect(card.blurhash == "UcQmF#ay~qofj[WBj[j[~qof9Fayofofayay")

        let result = try #require(status.filtered.first)
        #expect(status.filtered.count == 1)
        #expect(result.filter.id == "19972")
        #expect(result.filter.title == "ネタバレ")
        #expect(result.filter.context == [.home, .public])
        #expect(result.filter.filterAction == .warn)
        #expect(result.filter.expiresAt == nil)
        #expect(result.keywordMatches == ["最終回"])
        #expect(result.statusMatches == nil)

        #expect(status.editedAt == Date(timeIntervalSince1970: 1_791_864_000))
        #expect(status.bookmarked)
    }

    /// ブーストされた投稿の中身でも読める。
    @Test func decodesExtrasInsideReblog() throws {
        let status = try decodeFixture("status_reblog_with_poll_and_card")

        #expect(status.poll == nil)
        #expect(status.card == nil)
        #expect(status.filtered.isEmpty)
        #expect(status.editedAt == nil)
        #expect(!status.bookmarked)

        let reblog = try #require(status.reblog)
        let poll = try #require(reblog.poll)
        #expect(poll.expiresAt == nil)
        #expect(poll.expired)
        #expect(poll.votersCount == nil)
        // 結果を公開していない投票では、選択肢ごとの票の数がnull。
        #expect(poll.options.map(\.votesCount) == [nil, nil])
        // 自分の操作を表す項目が無ければ、投票していないものとする。
        #expect(!poll.voted)
        #expect(poll.ownVotes.isEmpty)

        let card = try #require(reblog.card)
        #expect(card.type == .video)
        #expect(card.image == nil, "空のサムネイルはnilにします")
        #expect(card.blurhash == nil)

        let result = try #require(reblog.filtered.first)
        #expect(result.filter.filterAction == .hide)
        #expect(result.filter.expiresAt == Date(timeIntervalSince1970: 1_796_083_200))
        #expect(result.keywordMatches == nil)
        #expect(result.statusMatches == ["113000000000000301"])

        #expect(reblog.editedAt == Date(timeIntervalSince1970: 1_791_867_600))
        #expect(reblog.bookmarked)
    }

    /// トークンなしで読んだときや、項目が加わる前の版のサーバーの応答。
    @Test func missingExtrasBecomeEmpty() throws {
        let status = try decodeFixture("status")

        #expect(status.poll == nil)
        #expect(status.card == nil)
        #expect(status.filtered.isEmpty)
        #expect(status.editedAt == nil)
        #expect(!status.bookmarked)
    }

    @Test func unknownCardTypeAndFilterActionAreKept() throws {
        let status = try decodeModified { json in
            var card = try #require(json["card"] as? [String: Any])
            card["type"] = "embed"
            card.removeValue(forKey: "author_name")
            json["card"] = card
            var result = try #require((json["filtered"] as? [[String: Any]])?.first)
            var filter = try #require(result["filter"] as? [String: Any])
            filter["filter_action"] = "mute"
            filter["context"] = ["home", "lists"]
            result["filter"] = filter
            json["filtered"] = [result]
        }

        #expect(status.card?.type == .unknown("embed"))
        #expect(status.card?.authorName == nil, "非推奨になった作者の名前は、無ければnilにします")
        #expect(status.filtered.first?.filter.filterAction == .other("mute"))
        #expect(status.filtered.first?.filter.context == [.home, .other("lists")])
    }

    /// 投票、カード、編集した日時が壊れていても、投稿は読め、壊れたものだけがなくなる。
    @Test func brokenPollCardAndEditDateAreDropped() throws {
        let droppedBefore = DecodingLog.droppedCount
        let status = try decodeModified { json in
            var poll = try #require(json["poll"] as? [String: Any])
            // 選択肢が1つでも読めなければ、位置がずれないよう投票ごと外す。
            poll["options"] = [["title": "りんご", "votes_count": 5], ["votes_count": 3]]
            json["poll"] = poll
            var card = try #require(json["card"] as? [String: Any])
            card["url"] = ""
            json["card"] = card
            json["edited_at"] = "yesterday"
        }

        #expect(status.id == "113000000000000201")
        #expect(status.poll == nil)
        #expect(status.card == nil)
        #expect(status.editedAt == nil)
        #expect(status.bookmarked)
        #expect(status.filtered.count == 1)
        // 数はプロセス全体で数えるため、並行する他のテストでも増える。
        #expect(DecodingLog.droppedCount >= droppedBefore + 3)
    }

    @Test func extrasOfWrongShapeAreDropped() throws {
        let status = try decodeModified { json in
            json["poll"] = "34830"
            json["card"] = ["https://news.example/articles/1"]
            json["edited_at"] = 1_791_864_000
        }

        #expect(status.poll == nil)
        #expect(status.card == nil)
        #expect(status.editedAt == nil)
    }

    /// 読めないフィルターの結果だけを外す。
    @Test func brokenFilterResultIsDropped() throws {
        let status = try decodeModified { json in
            let readable = try #require((json["filtered"] as? [[String: Any]])?.first)
            json["filtered"] = [["filter": ["title": "IDがない", "context": ["home"], "filter_action": "hide"]], readable]
        }

        #expect(status.filtered.map(\.filter.id) == ["19972"])
    }

    /// `filtered`が配列でなければ、メンションなどの配列と同じく投稿ごと読めない。
    @Test func filteredOfWrongShapeMakesStatusUnreadable() throws {
        #expect(throws: DecodingError.self) {
            try decodeModified { json in json["filtered"] = ["filter": [:]] }
        }
    }

    /// `bookmarked`の形が違えば、`favourited`と同じく投稿ごと読めない。
    @Test func bookmarkedOfWrongShapeMakesStatusUnreadable() throws {
        #expect(throws: DecodingError.self) {
            try decodeModified { json in json["bookmarked"] = "true" }
        }
    }

    @Test func settingBookmarkedChangesOnlyBookmark() throws {
        let status = try decodeFixture("status")

        let bookmarked = status.settingBookmarked(true)
        #expect(bookmarked.bookmarked)
        #expect(bookmarked.favouritesCount == status.favouritesCount)
        #expect(!bookmarked.settingBookmarked(false).bookmarked)
    }

    private func decodeFixture(_ name: String) throws -> Status {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try MastodonDecoder.make().decode(Status.self, from: Data(contentsOf: url))
    }

    @discardableResult
    private func decodeModified(_ modify: (inout [String: Any]) throws -> Void) throws -> Status {
        let url = try #require(Bundle.module.url(forResource: "status_with_poll_and_card", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try modify(&json)
        return try MastodonDecoder.make().decode(Status.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
