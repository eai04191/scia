public import Foundation

/// HTTPの`Link`ヘッダー（RFC 8288）の、`rel`ごとのURL。
/// Mastodonは、ブックマークやお気に入りのように、投稿のIDではない内部のIDで続きを読むAPIで、続きの位置をこのヘッダーで返す。
/// https://docs.joinmastodon.org/api/guidelines/#pagination
public struct LinkHeader: Equatable, Sendable {
    /// `rel`の値と、そのURL。1つの`rel`に複数の値（`rel="next prev"`）があれば、それぞれに同じURLを入れる。
    public let links: [String: URL]

    public init(links: [String: URL]) {
        self.links = links
    }

    /// `<URL>; rel="next", <URL>; rel="prev"`の形を読む。読めない要素は捨てる。
    public init(_ value: String) {
        var links: [String: URL] = [:]
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let target = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            // 次の要素の始まりまでが、この要素の引数。URLの中には`,`が入りうるため、`,`では区切らない。
            let parametersEnd = rest.firstIndex(of: "<") ?? rest.endIndex
            let parameters = rest[..<parametersEnd]
            rest = rest[parametersEnd...]
            guard let url = URL(string: String(target)) else { continue }
            for rel in Self.rels(in: parameters) where links[rel] == nil {
                links[rel] = url
            }
        }
        self.links = links
    }

    public var next: URL? { links["next"] }

    /// `rel`の値を、小文字にして空白で分ける。値は引用符で囲まれていてもいなくてもよい。
    private static func rels(in parameters: Substring) -> [String] {
        for parameter in parameters.split(separator: ";") {
            let parts = parameter.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "rel" else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.lowercased().split(separator: " ").map(String.init)
        }
        return []
    }

    /// `rel`のURLのクエリにある`name`の値。
    public func queryValue(_ name: String, of rel: String) -> String? {
        guard let url = links[rel] else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
