import Foundation

/// Unicodeの絵文字1つ。投稿欄の絵文字のシートで、カスタム絵文字の後ろに並べ、補完でも出す。
/// データは`Tools/build-emoji-data.py`で、Unicodeの絵文字の一覧（emoji-test.txt）、CLDRの絵文字の注釈、gemojiの短縮名から作る。
public struct StandardEmoji: Hashable, Sendable, Decodable {
    /// 絵文字そのもの。本文にはこの文字をそのまま入れる。
    public let emoji: String
    /// 日本語の名前。CLDRの読み上げの名前。
    public let name: String
    /// 英語の名前（emoji-test.txtの名前）。
    public let englishName: String
    /// 検索に使う、日本語と英語の言葉。
    public let keywords: [String]
    /// GitHubやSlackで使われる短縮名（`+1`、`thumbsup`など）。gemojiにないものは空。
    public let shortcodes: [String]
    /// その絵文字が入ったUnicodeの絵文字の版（「15.1」など）。
    public let version: String
    /// 検索で比べる、そろえた名前（日本語、英語、短縮名）と言葉。打つたびにそろえ直すと、全部で数十msかかるため、作るときに一度だけそろえる。
    let searchNames: [String]
    let searchKeywords: [String]
    /// 名前と言葉を英数字以外で分けた、英語の単語。単語を空白なしでつなげて打ったときに比べる。打つたびに分けると遅いため、作るときに一度だけ分ける。
    let searchWords: [[UInt8]]

    public init(emoji: String, name: String, englishName: String = "", keywords: [String], shortcodes: [String] = [], version: String) {
        self.emoji = emoji
        self.name = name
        self.englishName = englishName
        self.keywords = keywords
        self.shortcodes = shortcodes
        self.version = version
        searchNames = ([name, englishName] + shortcodes).map(StandardEmojiSearch.normalize).filter { !$0.isEmpty }
        searchKeywords = keywords.map(StandardEmojiSearch.normalize)
        let words = (searchNames + searchKeywords).flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        searchWords = Set(words.filter { $0.allSatisfy(\.isASCII) }.map(String.init)).sorted().map { Array($0.utf8) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            emoji: container.decode(String.self, forKey: .emoji),
            name: container.decode(String.self, forKey: .name),
            englishName: container.decode(String.self, forKey: .englishName),
            keywords: container.decode([String].self, forKey: .keywords),
            shortcodes: container.decodeIfPresent([String].self, forKey: .shortcodes) ?? [],
            version: container.decode(String.self, forKey: .version)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case emoji = "e"
        case name = "n"
        case englishName = "en"
        case keywords = "k"
        case shortcodes = "s"
        case version = "v"
    }
}

/// Unicodeの絵文字のまとまり（顔と感情、人と体など）。並びはemoji-test.txtの順で、iOSの絵文字キーボードとほぼ同じ。
public struct StandardEmojiGroup: Hashable, Sendable, Decodable {
    public let title: String
    public let emojis: [StandardEmoji]

    public init(title: String, emojis: [StandardEmoji]) {
        self.title = title
        self.emojis = emojis
    }
}

/// アプリに入れたUnicodeの絵文字の一覧。
public enum StandardEmojiCatalog {
    private struct File: Decodable {
        let groups: [StandardEmojiGroup]
    }

    /// 一覧。読めなければ空にする。データはアプリに入れたものなので、読めないのは作りの誤りで、テストで確かめる。
    public static let groups: [StandardEmojiGroup] = {
        guard let url = Bundle.module.url(forResource: "standard-emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.groups
    }()
}

/// Unicodeの絵文字を、名前（日本語、英語、短縮名）と言葉の文字列一致で探す。
///
/// ひらがなとカタカナ、全角と半角、大文字と小文字は区別しない。「ねこ」で「ネコ」や「猫」の言葉を持つ絵文字が見つかるよう、言葉ごとに比べる。
/// 名前と一致するもの、言葉と一致するもの、名前（英語は名前の中の単語）が語で始まるもの、言葉が語で始まるもの、名前か言葉が語を含むものの順に並べる。
/// 名前を言葉より先にするのは、補完では候補が数件しか出ないため。データの順のままだと、「fire」で🔥より❤️‍🔥や🧑‍🚒が、「heart」で❤️より🥰が先に出る。
/// 語で始まるものの中は、一致した語の短い順にし、ほかは一覧の順のままにする。
/// 語を含むものは、語に英数字以外が入るときだけ探す。英語で途中の一致まで拾うと、「cat」で「education」や「location」が当たるため。
/// 日本語は単語の区切りがないので、「ねこ」で「黒ねこ」のような途中の一致も拾う。
/// 補完の語には空白を打てないので、英語は名前と言葉の単語を空白なしでつなげて打っても探す（`newy`で`new`と`york`を持つ🗽）。`_`は単語の区切りとして読み飛ばす。
/// CLDRの英語の言葉は「New York」を`new`と`york`のように単語に分けて持ち、元の語順は残っていないので、語順は問わない。ほかの合い方より後に並べる。
public enum StandardEmojiSearch {
    public static func candidates(matching query: String, in groups: [StandardEmojiGroup], limit: Int) -> [StandardEmoji] {
        guard limit > 0 else { return [] }
        return Array(matches(matching: query, in: groups).prefix(limit).map(\.emoji))
    }

    /// 合ったところ。並べる順に、名前と一致、言葉と一致、名前が語で始まる、言葉が語で始まる、名前か言葉が語を含む、単語をつなげたものと合う。
    /// 語を含むものは日本語だけ、単語をつなげたものは英語だけで探すので、同じ語で両方が出ることはない。
    enum MatchKind: Int, Comparable {
        case nameExact
        case keywordExact
        case namePrefix
        case keywordPrefix
        case contained
        case joinedWords

        static func < (lhs: MatchKind, rhs: MatchKind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// 合う絵文字を、並べる順に、合ったところと組にして返す。補完で、カスタム絵文字と合ったところで混ぜて並べるのに使う。
    static func matches(matching query: String, in groups: [StandardEmojiGroup]) -> [(emoji: StandardEmoji, kind: MatchKind)] {
        let query = normalize(query)
        guard !query.isEmpty else { return [] }
        let matchesInside = !query.allSatisfy(\.isASCII)
        var ranked: [(kind: MatchKind, length: Int, index: Int, emoji: StandardEmoji)] = []
        for (index, emoji) in groups.lazy.flatMap(\.emojis).enumerated() {
            if let (kind, length) = match(of: emoji, query: query, matchesInside: matchesInside) {
                ranked.append((kind, length, index, emoji))
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.length != rhs.length ? lhs.length < rhs.length : lhs.index < rhs.index
        }
        return ranked.map { ($0.emoji, $0.kind) }
    }

    /// 合ったところと、語で始まるものなら一致した語の長さ。
    private static func match(of emoji: StandardEmoji, query: String, matchesInside: Bool) -> (MatchKind, Int)? {
        if emoji.searchNames.contains(query) { return (.nameExact, 0) }
        if emoji.searchKeywords.contains(query) { return (.keywordExact, 0) }
        if let length = shortestPrefixMatch(of: query, in: emoji.searchNames) { return (.namePrefix, length) }
        if let length = shortestPrefixMatch(of: query, in: emoji.searchKeywords) { return (.keywordPrefix, length) }
        if matchesInside, (emoji.searchNames + emoji.searchKeywords).contains(where: { $0.contains(query) }) { return (.contained, 0) }
        if !matchesInside, matchesJoinedWords(Array(query.utf8.filter { $0 != UInt8(ascii: "_") }), in: emoji.searchWords) { return (.joinedWords, 0) }
        return nil
    }

    /// 語が、単語を丸ごと1つ以上つなげ、最後に単語の始まりを付けたものになっているか。同じ単語を何度使ってもよい。
    /// 何文字目まで丸ごとの単語で切り終えられるかだけを覚えて頭から進めるので、切り方がいくつあっても、手間は語の長さと単語の数で頭打ちになる。
    private static func matchesJoinedWords(_ query: [UInt8], in words: [[UInt8]]) -> Bool {
        guard !query.isEmpty else { return false }
        var reachable = [Bool](repeating: false, count: query.count)
        reachable[0] = true
        for start in query.indices where reachable[start] {
            let rest = query[start...]
            for word in words {
                if start > 0, word.starts(with: rest) { return true }
                if word.count < rest.count, rest.starts(with: word) { reachable[start + word.count] = true }
            }
        }
        return false
    }

    /// 語で始まる言葉（英語は言葉の中の単語）のうち、いちばん短いものの長さ。なければnil。
    private static func shortestPrefixMatch(of query: String, in words: [String]) -> Int? {
        var shortest: Int?
        for word in words {
            let parts = [Substring(word)] + word.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            for part in parts where part.hasPrefix(query) {
                shortest = min(shortest ?? part.count, part.count)
            }
        }
        return shortest
    }

    /// 比べる前にそろえる。全角と半角は互換分解でそろえ、カタカナはひらがなにし、大文字は小文字にする。前後の空白は除く。
    static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let hiragana = folded.applyingTransform(.hiraganaToKatakana, reverse: true) ?? folded
        return hiragana.trimmingCharacters(in: .whitespaces)
    }
}
