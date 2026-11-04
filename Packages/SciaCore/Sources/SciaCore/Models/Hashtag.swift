public import Foundation

/// https://docs.joinmastodon.org/entities/Tag/
public struct Hashtag: Decodable, Hashable, Sendable {
    /// `#`を除いた名前。サーバーが小文字にそろえることがある。
    public let name: String
    public let url: URL?
    /// 日ごとの使われた数。新しい日から並ぶ。返さないサーバーでは空。
    public let history: [History]

    /// https://docs.joinmastodon.org/entities/Tag/#history
    public struct History: Hashable, Sendable {
        /// その日に使われた投稿の数。
        public let uses: Int
        /// その日に使ったアカウントの数。
        public let accounts: Int

        public init(uses: Int, accounts: Int) {
            self.uses = uses
            self.accounts = accounts
        }
    }

    public init(name: String, url: URL? = nil, history: [History] = []) {
        self.name = name
        self.url = url
        self.history = history
    }

    /// 投稿に付いていたタグを、渡された投稿の順、投稿の中の順に並べる。サーバーが同じタグとして扱う表記は、先に出たものだけを残す。
    public static func used(in statuses: [Status]) -> [Hashtag] {
        unique(statuses.flatMap(\.tags).map { Hashtag(name: $0.name, url: $0.url) })
    }

    /// サーバーが同じタグとして扱う表記を、先に出たものだけを残して除く。
    static func unique(_ tags: [Hashtag]) -> [Hashtag] {
        var seen = Set<String>()
        return tags.filter { seen.insert(normalizedName($0.name)).inserted }
    }

    /// サーバー全体で最近使われた順に並べる。最後に使われた日が新しい順、同じ日の中ではその日に使われた数が多い順にし、
    /// `query`と同じ名前のタグは先頭に置く。日ごとの数は過去7日しかなく、日より細かい順も分からないので、
    /// 同じ順位のタグと、7日のうちに使われていないタグは、渡された順のまま残す。
    public static func orderedByRecentUse(_ tags: [Hashtag], query: String) -> [Hashtag] {
        let normalizedQuery = normalizedName(query)
        return tags.enumerated().sorted { lhs, rhs in
            let left = recentUseRank(lhs.element, normalizedQuery: normalizedQuery)
            let right = recentUseRank(rhs.element, normalizedQuery: normalizedQuery)
            if left.isExact != right.isExact { return left.isExact }
            if left.daysAgo != right.daysAgo { return left.daysAgo < right.daysAgo }
            if left.uses != right.uses { return left.uses > right.uses }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func recentUseRank(_ tag: Hashtag, normalizedQuery: String) -> (isExact: Bool, daysAgo: Int, uses: Int) {
        let lastUsed = tag.history.firstIndex { $0.uses > 0 }
        return (
            normalizedName(tag.name) == normalizedQuery,
            lastUsed ?? Int.max,
            lastUsed.map { tag.history[$0].uses } ?? 0
        )
    }

    /// サーバーが同じタグかを見分けるときの名前。Mastodonの`HashtagNormalizer`と同じく、NFKCで全角と半角などをそろえ、
    /// 小文字にし、ラテン文字のアクセント記号を外し（`ASCIIFolding`）、タグに使えない文字を除く。
    /// アクセント記号はサーバーと同じ表の文字だけを外し、日本語の濁点などは外さない。
    public static func normalizedName(_ name: String) -> String {
        let folded = String(name.precomposedStringWithCompatibilityMapping.lowercased().map { asciiFolding[$0] ?? $0 })
        return String(folded.unicodeScalars.filter(isValidScalar).map(Character.init))
    }

    /// 投稿のタグの名前を、`normalizedName`でそろえた集合にする。`isTagText`に渡す。
    static func normalizedNames(of tags: [Tag]) -> Set<String> {
        Set(tags.map { normalizedName($0.name) })
    }

    /// リンクの文字列が、投稿のタグのどれかの名前に`#`を付けたものか。
    /// Misskeyの投稿のハッシュタグは、`class`がなく、`rel`も`nofollow noopener`に書き換わって届くため、リンクの属性では見分けられない。
    /// `normalizedNames`は`normalizedNames(of:)`でそろえたもの。`text`は文字参照を戻したものを渡す。
    static func isTagText(_ text: String, normalizedNames: Set<String>) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.first == "#" else { return false }
        return normalizedNames.contains(normalizedName(name(ofTagText: trimmed)))
    }

    /// リンクの文字列から先頭の`#`を外した名前。
    /// 文字（書記素クラスタ）ではなくUnicodeのスカラー値で外す。名前が`U+FE0F U+20E3`で始まると、`#`とつながって
    /// キーキャップの絵文字`#️⃣`の1文字になり、文字で外すと`#`が残るため。
    static func name(ofTagText text: String) -> String {
        String(text.unicodeScalars.drop { $0 == "#" })
    }

    private static let asciiFolding: [Character: Character] = {
        let from = Array("ÀÁÂÃÄÅàáâãäåĀāĂăĄąÇçĆćĈĉĊċČčÐðĎďĐđÈÉÊËèéêëĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħÌÍÎÏìíîïĨĩĪīĬĭĮįİıĴĵĶķĸĹĺĻļĽľĿŀŁłÑñŃńŅņŇňŉŊŋÒÓÔÕÖØòóôõöøŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšſŢţŤťŦŧÙÚÛÜùúûüŨũŪūŬŭŮůŰűŲųŴŵÝýÿŶŷŸŹźŻżŽž")
        let to = Array("AAAAAAaaaaaaAaAaAaCcCcCcCcCcDdDdDdEEEEeeeeEeEeEeEeEeGgGgGgGgHhHhIIIIiiiiIiIiIiIiIiJjKkkLlLlLlLlLlNnNnNnNnnNnOOOOOOooooooOoOoOoRrRrRrSsSsSsSssTtTtTtUUUUuuuuUuUuUuUuUuUuWwYyyYyYZzZzZz")
        return Dictionary(zip(from, to), uniquingKeysWith: { first, _ in first })
    }()

    /// `HASHTAG_INVALID_CHARS_RE`（`[^[:alnum:]\u0E47-\u0E4E_·・ZWNJ]`）に当たらない文字。
    private static func isValidScalar(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.isAlphabetic || properties.numericType == .decimal
            || (0x0E47 ... 0x0E4E).contains(scalar.value)
            || ["_", "\u{00B7}", "\u{30FB}", "\u{200C}"].contains(scalar)
    }

    /// 履歴にある日（Mastodonは直近の7日）に使われた投稿の数の合計。web UIの候補と同じく、人気の目安に出す。
    public var recentUses: Int {
        ServerCount.sum(history.map(\.uses))
    }

    private enum CodingKeys: String, CodingKey {
        case name, url, history
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = container.decodeURL(.destination, forKey: .url)
        // 履歴は人気の目安にしか使わないので、読めなくても名前だけで候補にする。
        history = (try? container.decodeIfPresent([History].self, forKey: .history)) ?? []
    }
}

extension Hashtag.History: Decodable {
    private enum CodingKeys: String, CodingKey {
        case uses, accounts
    }

    /// Mastodonは数を文字列で返す。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uses = Self.count(container, .uses)
        accounts = Self.count(container, .accounts)
    }

    private static func count(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
        if let text = try? container.decode(String.self, forKey: key) { return Int(text).map(ServerCount.clamped) ?? 0 }
        return (try? container.decodeCount(forKey: key)) ?? 0
    }
}
