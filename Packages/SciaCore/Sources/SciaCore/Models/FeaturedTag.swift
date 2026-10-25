import Foundation

/// プロフィールに載せているハッシュタグ。
/// https://docs.joinmastodon.org/entities/FeaturedTag/
public struct FeaturedTag: Decodable, Hashable, Sendable {
    /// `#`を除いた名前。
    public let name: String
    /// このタグを付けた自分の投稿の数。
    public let statusesCount: Int

    public init(name: String, statusesCount: Int) {
        self.name = name
        self.statusesCount = statusesCount
    }

    private enum CodingKeys: String, CodingKey {
        case name, statusesCount
    }

    /// 文書では`statuses_count`は文字列だが、Mastodonは数で返す。どちらでも読み、読めなければ0にする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let count = try? container.decodeCount(forKey: .statusesCount) {
            statusesCount = count
        } else {
            statusesCount = (try? container.decode(String.self, forKey: .statusesCount)).flatMap { Int($0) }.map(ServerCount.clamped) ?? 0
        }
    }
}

/// 自分が使うハッシュタグ。補完で、サーバーの検索結果より上に出す。
public struct OwnHashtag: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// プロフィールに載せているタグ。自分の投稿の数を持つ。
        case featured(statusesCount: Int)
        /// 最近使ったタグ（`api/v1/featured_tags/suggestions`）。
        case recent
    }

    public let name: String
    public let source: Source

    public init(name: String, source: Source) {
        self.name = name
        self.source = source
    }

    /// プロフィールに載せているタグを投稿の多い順に、続けて最近使ったタグをサーバーが返した順に並べる。
    /// 同じ名前は、プロフィールに載せている方だけを残す。
    public static func list(featured: [FeaturedTag], recent: [Hashtag]) -> [OwnHashtag] {
        // サーバーが同じタグとして扱う表記は、1つにまとめる。
        var seen = Set<String>()
        var result: [OwnHashtag] = []
        let sortedFeatured = featured.enumerated().sorted { lhs, rhs in
            lhs.element.statusesCount != rhs.element.statusesCount ? lhs.element.statusesCount > rhs.element.statusesCount : lhs.offset < rhs.offset
        }
        for tag in sortedFeatured.map(\.element) where seen.insert(Hashtag.normalizedName(tag.name)).inserted {
            result.append(OwnHashtag(name: tag.name, source: .featured(statusesCount: tag.statusesCount)))
        }
        for tag in recent where seen.insert(Hashtag.normalizedName(tag.name)).inserted {
            result.append(OwnHashtag(name: tag.name, source: .recent))
        }
        return result
    }

    /// 打った語で始まるものを先に、語を含むものを後に並べる。サーバーと同じく、大文字小文字や全角半角、アクセント記号の違いは見ない。
    /// それぞれの中は`tags`の順（プロフィールのタグが先）のまま。語が空なら全部を返す。
    public static func matching(_ query: String, in tags: [OwnHashtag]) -> [OwnHashtag] {
        let query = Hashtag.normalizedName(query)
        guard !query.isEmpty else { return tags }
        let names = tags.map { Hashtag.normalizedName($0.name) }
        let prefixed = zip(tags, names).filter { $0.1.hasPrefix(query) }.map(\.0)
        let contained = zip(tags, names).filter { !$0.1.hasPrefix(query) && $0.1.contains(query) }.map(\.0)
        return prefixed + contained
    }
}
