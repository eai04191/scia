import Foundation
import Testing
@testable import SciaCore

@MainActor
struct EmojiPaletteTests {
    private func emoji(_ shortcode: String, category: String? = nil, visible: Bool = true) throws -> ServerEmoji {
        let url = try #require(URL(string: "https://example.social/emoji/\(shortcode).png"))
        return ServerEmoji(shortcode: shortcode, url: url, staticUrl: url, visibleInPicker: visible, category: category)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "EmojiPaletteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - まとまり

    /// 最近使ったもの、カテゴリーのないもの、カテゴリーの名前の順に並べ、中はサーバーの順のまま。
    @Test func ordersSections() throws {
        let emojis = [
            try emoji("zebra", category: "animals"),
            try emoji("blobcat"),
            try emoji("apple", category: "Food"),
            try emoji("ant", category: "animals"),
            try emoji("aaa"),
        ]
        let sections = EmojiPalette.sections(emojis: emojis, standardGroups: [], recentKeys: ["apple"], recentLimit: 10)
        #expect(sections.map(\.kind) == [.recent, .uncategorized, .category("animals"), .category("Food")])
        #expect(sections.map { $0.emojis.map(\.recentKey) } == [["apple"], ["blobcat", "aaa"], ["zebra", "ant"], ["apple"]])
    }

    /// 一覧に出さない絵文字と、サーバーからなくなった最近の絵文字は出さない。空のまとまりは作らない。
    @Test func dropsHiddenAndRemovedEmojis() throws {
        let emojis = [try emoji("shown"), try emoji("hidden", visible: false)]
        let sections = EmojiPalette.sections(emojis: emojis, standardGroups: [], recentKeys: ["removed", "hidden"], recentLimit: 10)
        #expect(sections.map(\.kind) == [.uncategorized])
        #expect(sections.first?.emojis.map(\.recentKey) == ["shown"])
    }

    @Test func limitsRecentEmojis() throws {
        let emojis = try ["a1", "a2", "a3"].map { try emoji($0) }
        let sections = EmojiPalette.sections(emojis: emojis, standardGroups: [], recentKeys: ["a3", "a1", "a2"], recentLimit: 2)
        #expect(sections.first?.emojis.map(\.recentKey) == ["a3", "a1"])
    }

    // MARK: - 最近使った絵文字

    /// 使い直したものは先頭へ移し、起動し直しても覚えている。
    @Test func recordsMostRecentFirst() throws {
        let defaults = try makeDefaults()
        let instance = try #require(URL(string: "https://example.social"))
        let recent = RecentEmojis(defaults: defaults, instance: instance)
        recent.record("a1")
        recent.record("a2")
        recent.record("a1")
        #expect(RecentEmojis(defaults: defaults, instance: instance).keys == ["a1", "a2"])
    }

    /// 同じサーバーを2つのウィンドウで開いていても、片方で選んだものを、もう片方で選んだときに消さない。
    @Test func sharesHistoryAcrossWindows() throws {
        let defaults = try makeDefaults()
        let instance = try #require(URL(string: "https://example.social"))
        let first = RecentEmojis(defaults: defaults, instance: instance)
        let second = RecentEmojis(defaults: defaults, instance: instance)
        first.record("blobcat")
        #expect(second.keys == ["blobcat"])
        second.record("partyparrot")
        #expect(RecentEmojis(defaults: defaults, instance: instance).keys == ["partyparrot", "blobcat"])
    }

    @Test func keepsServersApart() throws {
        let defaults = try makeDefaults()
        RecentEmojis(defaults: defaults, instance: try #require(URL(string: "https://example.social"))).record("a1")
        #expect(RecentEmojis(defaults: defaults, instance: try #require(URL(string: "https://other.example"))).keys.isEmpty)
    }

    @Test func forgetsBeyondCapacity() throws {
        let recent = RecentEmojis(defaults: try makeDefaults(), instance: try #require(URL(string: "https://example.social")))
        for index in 0 ..< RecentEmojis.capacity + 5 {
            recent.record("e\(index)")
        }
        #expect(recent.keys.count == RecentEmojis.capacity)
        #expect(recent.keys.first == "e\(RecentEmojis.capacity + 4)")
    }

    // MARK: - 入れる

    private func insert(_ marked: String) -> String {
        let parts = marked.components(separatedBy: "|")
        let text = parts.joined()
        let cursor = parts[0].utf16.count
        let insertion = CompletionTokenizer.insertion(of: ":blob:", at: cursor ..< cursor, in: text)
        var utf16 = Array(text.utf16)
        utf16.replaceSubrange(insertion.range, with: Array(insertion.text.utf16))
        utf16.insert(contentsOf: Array("|".utf16), at: insertion.cursor)
        return String(decoding: utf16, as: UTF16.self)
    }

    /// 空白、行頭、記号の後ろにはそのまま入れ、英数字、日本語、`:`の後ろには空白を挟む。後ろには空白を足して続けて入れられるようにする。
    @Test func insertsWithSpacesTheServerNeeds() {
        #expect(insert("|") == ":blob: |")
        #expect(insert("hi |") == "hi :blob: |")
        #expect(insert("a\n|") == "a\n:blob: |")
        #expect(insert("（|") == "（:blob: |")
        #expect(insert("hi|") == "hi :blob: |")
        #expect(insert("ねこ|") == "ねこ :blob: |")
        #expect(insert(":a:|") == ":a: :blob: |")
    }

    /// 後ろに空白があれば足さず、空白の後ろへカーソルを置く。後ろに文が続けば空白で区切る。
    @Test func insertsBeforeFollowingText() {
        #expect(insert("| です") == ":blob: |です")
        #expect(insert("|です") == ":blob: |です")
    }

    @Test func replacesSelection() {
        let insertion = CompletionTokenizer.insertion(of: ":blob:", at: 3 ..< 6, in: "hi abc")
        #expect(insertion.range == 3 ..< 6)
        #expect(insertion.text == ":blob: ")
    }

    // MARK: - 消す

    @Test func deletesWholeShortcode() {
        let text = "hi :blob: "
        let end = text.utf16.count
        #expect(CompletionTokenizer.emojiDeletionRange(before: end ..< end, in: text) == 3 ..< end)
        #expect(CompletionTokenizer.emojiDeletionRange(before: 9 ..< 9, in: text) == 3 ..< 9)
        #expect(CompletionTokenizer.emojiDeletionRange(before: 6 ..< 6, in: ":blob:") == 0 ..< 6)
    }

    /// 絵文字でなければ、選んでいれば、ふつうに消す。
    @Test func fallsBackToCharacterDeletion() {
        #expect(CompletionTokenizer.emojiDeletionRange(before: 5 ..< 5, in: "hello") == nil)
        #expect(CompletionTokenizer.emojiDeletionRange(before: 0 ..< 6, in: ":blob:") == nil)
        #expect(CompletionTokenizer.emojiDeletionRange(before: 3 ..< 3, in: ":a:") == nil)
        #expect(CompletionTokenizer.emojiDeletionRange(before: 7 ..< 7, in: "time 1:") == nil)
    }

    // MARK: - Unicodeの絵文字

    private func standard(_ emoji: String, _ name: String, _ keywords: [String]) -> StandardEmoji {
        StandardEmoji(emoji: emoji, name: name, keywords: keywords, version: "1.0")
    }

    /// アプリに入れた一覧が読め、まとまりごとに並ぶ。
    @Test func loadsBundledStandardEmoji() throws {
        let groups = StandardEmojiCatalog.groups
        #expect(groups.map(\.title) == ["顔と感情", "人と体", "動物と自然", "食べ物と飲み物", "旅行と場所", "活動", "物", "記号", "旗"])
        #expect(groups.first?.emojis.first?.emoji == "😀")
        #expect(groups.flatMap(\.emojis).count > 1500)
    }

    /// Unicodeの絵文字は、カスタム絵文字の後ろにまとまりごとに並べ、最近使ったものにも入る。
    @Test func appendsStandardGroupsAfterCustomEmojis() throws {
        let groups = [StandardEmojiGroup(title: "動物と自然", emojis: [standard("🐈", "ネコ", ["猫"])])]
        let sections = EmojiPalette.sections(emojis: [try emoji("blobcat")], standardGroups: groups, recentKeys: ["🐈", "blobcat"], recentLimit: 10)
        #expect(sections.map(\.kind) == [.recent, .uncategorized, .standard("動物と自然")])
        #expect(sections.first?.emojis.map(\.recentKey) == ["🐈", "blobcat"])
    }

    /// ひらがなとカタカナ、全角と半角、大文字と小文字を区別せずに、言葉と一致するもの、言葉で始まるもの、言葉を含むものの順に並べる。
    @Test func searchesStandardEmojiByKeywords() {
        let groups = [StandardEmojiGroup(title: "動物と自然", emojis: [
            standard("🐱", "ネコの顔", ["顔", "ネコ"]),
            standard("🐈", "ネコ", ["猫", "ペット"]),
            standard("🐈‍⬛", "黒猫", ["ブラックキャット", "black cat"]),
            standard("🐶", "イヌの顔", ["dog"]),
        ])]
        #expect(StandardEmojiSearch.candidates(matching: "ねこ", in: groups, limit: 10).map(\.emoji) == ["🐱", "🐈"])
        #expect(StandardEmojiSearch.candidates(matching: "猫", in: groups, limit: 10).map(\.emoji) == ["🐈", "🐈‍⬛"])
        #expect(StandardEmojiSearch.candidates(matching: "ＣＡＴ", in: groups, limit: 10).map(\.emoji) == ["🐈‍⬛"])
        #expect(StandardEmojiSearch.candidates(matching: "  ", in: groups, limit: 10).isEmpty)
    }

    /// 英語は単語の頭だけで探し、単語の途中には当てない。
    @Test func englishQueryMatchesWordPrefixesOnly() {
        let groups = [StandardEmojiGroup(title: "物", emojis: [
            standard("🎓", "卒業帽", ["education", "graduation"]),
            standard("🐈", "ネコ", ["cat", "pet"]),
            standard("🐈‍⬛", "黒猫", ["black cat"]),
        ])]
        #expect(StandardEmojiSearch.candidates(matching: "cat", in: groups, limit: 10).map(\.emoji) == ["🐈", "🐈‍⬛"])
    }

    /// 実際の一覧で、日本語の言葉から探せる。
    @Test func searchesBundledStandardEmojiInJapanese() {
        let results = StandardEmojiSearch.candidates(matching: "ねこ", in: StandardEmojiCatalog.groups, limit: 20).map(\.emoji)
        #expect(results.contains("🐈"))
        #expect(StandardEmojiSearch.candidates(matching: "恐竜", in: StandardEmojiCatalog.groups, limit: 20).map(\.emoji).contains("🦖"))
    }

    /// 検索の結果は、カスタム絵文字の一致を先に、Unicodeの絵文字の一致を後に並べる。
    @Test func searchResultsPutCustomEmojisFirst() throws {
        let groups = [StandardEmojiGroup(title: "動物と自然", emojis: [standard("🐈", "ネコ", ["cat"])])]
        let results = EmojiPalette.searchResults(matching: "cat", emojis: [try emoji("blobcat")], standardGroups: groups, limit: 10)
        #expect(results.map(\.recentKey) == ["blobcat", "🐈"])
    }

    /// 日本語の入力のまま全角の英字で打っても、カスタム絵文字をショートコードで探せる。
    @Test func searchResultsFindCustomEmojisByFullwidthQuery() throws {
        let results = EmojiPalette.searchResults(matching: "ｂｌｏｂ", emojis: [try emoji("blobcat")], standardGroups: [], limit: 10)
        #expect(results.map(\.recentKey) == ["blobcat"])
    }
}
