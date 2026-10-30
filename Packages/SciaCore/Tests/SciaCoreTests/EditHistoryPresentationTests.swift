import Foundation
import Testing
@testable import SciaCore

struct EditHistoryPresentationTests {
    private let first = MediaAttachment(id: "1", type: .image, url: nil, previewUrl: nil)
    private let second = MediaAttachment(id: "2", type: .video, url: nil, previewUrl: nil)

    /// 古い版から並べた`revisions`の履歴。
    private func history(_ revisions: [(content: String, sensitive: Bool, media: [MediaAttachment], poll: [String]?)]) throws -> StatusEditHistory {
        let account = try MastodonDecoder.make().decode(Account.self, from: Data(Self.account.utf8))
        return StatusEditHistory(
            revisions: revisions.map {
                StatusRevision(content: $0.content, sensitive: $0.sensitive, createdAt: Date(timeIntervalSince1970: 0), account: account, mediaAttachments: $0.media, pollOptions: $0.poll)
            },
            mentions: [],
            tags: [],
            language: nil,
            minimumUnchangedRatio: 0.3
        )
    }

    private func entries(
        _ history: StatusEditHistory,
        latestCover: MediaCover? = nil,
        isHidden: Bool = false,
        filterTitles: [String] = [],
        revealed: Set<Int> = []
    ) -> [EditHistoryPresentation.Entry] {
        EditHistoryPresentation.entries(for: history, latestCover: latestCover, isHidden: isHidden, filterTitles: filterTitles, revealedEditNumbers: revealed)
    }

    @Test func titlesNameEachRevisionAndMarkTheLatest() throws {
        let result = entries(try history([
            ("<p>a</p>", false, [], nil),
            ("<p>b</p>", false, [], nil),
            ("<p>c</p>", false, [], nil),
        ]))

        #expect(result.map(\.title) == ["いまの投稿（2回目の編集）", "1回目の編集", "最初の投稿"])
    }

    @Test func notesNameChangesNotVisibleInText() throws {
        let result = entries(try history([
            ("<p>a</p>", false, [first, second], nil),
            ("<p>a</p>", true, [second, first], nil),
        ]))

        #expect(result[0].notes == ["閲覧注意を付けた", "メディアの並びを変えた"])
        #expect(result[1].notes == [])
    }

    /// 過去の版は、フィルター、閲覧注意、隠した、の順に理由を選んでぼかす。今の投稿の版は渡した理由に従う。
    @Test func pastRevisionsAreCoveredByFilterThenSensitiveThenHidden() throws {
        let sensitive = try history([("<p>a</p>", true, [first], nil), ("<p>b</p>", false, [first], nil)])
        let plain = try history([("<p>a</p>", false, [first], nil), ("<p>b</p>", false, [first], nil)])

        #expect(entries(sensitive, filterTitles: ["ネタバレ"])[1].mediaCover == .filtered(["ネタバレ"]))
        #expect(entries(sensitive, isHidden: true)[1].mediaCover == .sensitive)
        #expect(entries(plain, isHidden: true)[1].mediaCover == .hidden)
        #expect(entries(plain)[1].mediaCover == nil)
        #expect(entries(sensitive, revealed: [0])[1].mediaCover == nil)
        #expect(entries(sensitive, latestCover: .hidden)[0].mediaCover == .hidden)
    }

    /// 外した添付ファイルは、外す前の版の閲覧注意でぼかす。
    @Test func removedMediaIsCoveredByThePreviousRevision() throws {
        let result = entries(try history([
            ("<p>a</p>", true, [first, second], nil),
            ("<p>a</p>", false, [second], nil),
        ]))

        let change = try #require(result[0].mediaChanges.first)
        #expect(change.title == "画像を削除")
        #expect(change.isRemoved)
        #expect(change.cover == .sensitive)
        #expect(result[0].mediaCover == nil)
    }

    @Test func addedMediaIsNamedByKind() throws {
        let result = entries(try history([
            ("<p>a</p>", false, [], nil),
            ("<p>a</p>", false, [second], nil),
        ]))

        #expect(result[0].mediaChanges.map(\.title) == ["動画を追加"])
    }

    @Test func pollOptionsShowChangesAndSpeakThem() throws {
        let result = entries(try history([
            ("<p>どれ？</p>", false, [], ["猫", "犬"]),
            ("<p>どれ？</p>", false, [], ["猫", "鳥"]),
        ]))

        #expect(result[0].pollOptions?.map(\.text) == ["・猫", "・犬", "・鳥"])
        #expect(result[0].pollOptions?.map(\.accessibilityText) == ["猫", "削除：犬", "追加：鳥"])
        #expect(result[1].pollOptions?.map(\.change) == [.unchanged, .unchanged])
    }

    private static let account = #"{"id":"1","username":"alice","acct":"alice","display_name":"Alice","avatar":"https://example.social/avatars/alice.png","avatar_static":"https://example.social/avatars/alice.png","header":"https://example.social/headers/original/missing.png","header_static":"https://example.social/headers/original/missing.png","note":"","url":"https://example.social/@alice","fields":[],"locked":false,"bot":false,"followers_count":0,"following_count":0,"statuses_count":0,"emojis":[]}"#
}
