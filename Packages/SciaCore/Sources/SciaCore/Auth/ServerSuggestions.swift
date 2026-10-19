public import Foundation

/// ログイン画面で、打ちかけのサーバーのアドレスに合うサーバーを候補に出す。
/// 候補は端末の中だけで探し、打った文字を外へ送らない。
public struct ServerSuggestions: Sendable {
    public enum LoadError: Error {
        case missingResource
    }

    /// ログイン済みのアカウントのサーバーを先に、同梱の一覧を後に、重複なく並べたもの。
    private let domains: [String]

    /// - Parameters:
    ///   - accountDomains: ログイン済みのアカウントのサーバー。同じサーバーにもう1つのアカウントを足すときに、上に出す。
    ///   - knownDomains: 同梱の一覧。月間アクティブ数の多い順に並んでいる。
    public init(accountDomains: [String], knownDomains: [String]) {
        var seen = Set<String>()
        domains = (accountDomains.map { $0.lowercased() } + knownDomains).filter { seen.insert($0).inserted }
    }

    /// ログイン済みのアカウントのサーバーを、入力欄に入れる形（`host`か`host:port`）にする。
    /// ポートを落とすと、選んでログインしたときに443番へつなぎ、元のサーバーに届かないため残す。
    public static func address(of instance: URL) -> String? {
        guard let host = instance.host() else { return nil }
        return instance.port.map { "\(host):\($0)" } ?? host
    }

    /// FediDBのデータセットから`Tools/update-known-servers.sh`で作った一覧を読む。
    public static func loadKnownDomains() throws -> [String] {
        guard let url = Bundle.module.url(forResource: "known-servers", withExtension: "txt") else {
            throw LoadError.missingResource
        }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// 打ったものと同じもの、打ったもので始まるもの、打ったものを含むものの順に出す。
    /// それぞれの中では、ログイン済みのアカウントのサーバーを先に、ほかは月間アクティブ数の多い順に並べる。
    /// 何も打っていなければ、ログイン済みのサーバーと、月間アクティブ数の多いサーバーを出す。
    public func suggestions(for input: String, limit: Int = 5) -> [String] {
        let query = Self.normalize(input)
        guard !query.isEmpty else { return Array(domains.prefix(limit)) }

        var exact: [String] = []
        var prefix: [String] = []
        var contains: [String] = []
        for domain in domains {
            if domain == query {
                exact.append(domain)
            } else if domain.hasPrefix(query) {
                if prefix.count < limit { prefix.append(domain) }
            } else if contains.count < limit, domain.contains(query) {
                contains.append(domain)
            }
        }
        return Array((exact + prefix + contains).prefix(limit))
    }

    /// 候補の中で、打ったものに当たる部分。候補の行で太字にして、なぜその候補が出たかを見せる。
    /// 何も打っていないときと、当たらないときはnil。
    public static func matchedRange(of input: String, in domain: String) -> Range<String.Index>? {
        let query = normalize(input)
        guard !query.isEmpty else { return nil }
        return domain.range(of: query)
    }

    /// `https://`や末尾の`/`、`@alice@`のようなアカウントの部分を除き、ドメインとして比べられる形にする。
    static func normalize(_ input: String) -> String {
        var query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = query.range(of: "://") {
            query = String(query[range.upperBound...])
        }
        if let slash = query.firstIndex(of: "/") {
            query = String(query[..<slash])
        }
        if let at = query.lastIndex(of: "@") {
            query = String(query[query.index(after: at)...])
        }
        return query
    }
}
