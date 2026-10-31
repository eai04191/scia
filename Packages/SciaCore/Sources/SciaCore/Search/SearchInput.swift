public import Foundation

/// 検索欄に打った語の形。形によって、確定したときにすることと、打っている途中に出す行が変わる。決まりはdocs/search.mdにある。
public enum SearchInput: Equatable, Sendable {
    /// httpかhttpsのURL。サーバーに相手のサーバーから投稿やプロフィールを読み込ませる。
    case url(URL)
    /// `user@domain`の形のハンドル。`acct`は先頭の`@`を除いたもの。
    case handle(acct: String)
    /// `#`で始まる語。`name`は`#`を除いた名前。
    case hashtag(name: String)
    /// ほかの語。
    case text(String)

    /// 前後の空白を除いた`text`の形。空ならnil。
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = Self.url(in: trimmed) {
            self = .url(url)
        } else if let acct = Self.acct(in: trimmed) {
            self = .handle(acct: acct)
        } else if trimmed.hasPrefix("#"), trimmed.count > 1, !trimmed.contains(where: \.isWhitespace) {
            self = .hashtag(name: String(trimmed.dropFirst()))
        } else {
            self = .text(trimmed)
        }
    }

    /// サーバーに送る語。
    /// Mastodonは、語がスキームの小文字の`http://`か`https://`で始まるときだけURLとして読み込むため、URLはスキームを小文字にして送る。
    public var query: String {
        switch self {
        case .url(let url): url.absoluteString
        case .handle(let acct): acct
        case .hashtag(let name): "#\(name)"
        case .text(let text): text
        }
    }

    /// URLの形なら、スキームを小文字にしたURL。空白を含むものや、ホストのないものはURLとして扱わない。
    private static func url(in text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        return components.url
    }

    /// `@user@domain`か`user@domain`の形なら、先頭の`@`を除いたもの。ユーザー名は英数字と`_`、`.`、`-`、ドメインは`.`を含むもの。
    private static func acct(in text: String) -> String? {
        let body = text.hasPrefix("@") ? text.dropFirst() : text[...]
        let parts = body.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let username = parts[0], domain = parts[1]
        guard let first = username.first, first.isASCII, first.isLetter || first.isNumber || first == "_",
              username.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }),
              domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."),
              !domain.contains(where: { $0.isWhitespace || "/@:?#".contains($0) }) else { return nil }
        return String(body)
    }

    /// ハンドルの形の語が、`account`を指しているか。同じサーバーのユーザーの`acct`はサーバー名を含まないため、`credential`のサーバー名を付けて比べる。
    public func names(_ account: Account, on credential: Credential) -> Bool {
        guard case .handle(let acct) = self else { return false }
        return credential.handle(ofAcct: account.acct).lowercased() == credential.handle(ofAcct: acct).lowercased()
    }
}
