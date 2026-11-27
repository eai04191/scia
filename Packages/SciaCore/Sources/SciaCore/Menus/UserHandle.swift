import Foundation

/// ユーザーのメニューのコピーの項目で、ハンドルのどの部分をコピーするか。決まりはdocs/menus.mdの「ユーザーのメニュー」にある。
public enum UserHandlePart: Sendable, Equatable {
    /// `@username@domain`。
    case handle
    /// `@`を付けない`username`。
    case username
    /// `domain`。
    case server
}

/// `acct`を、ユーザー名とサーバーに分けたもの。
/// Mastodonの`acct`は、同じサーバーのユーザーではサーバー名を含まないため、ログインしているサーバーの名前を補う。
public struct UserHandle: Equatable, Sendable {
    public let username: String
    public let server: String

    /// - Parameter localServer: ログインしているサーバーの名前。`acct`にサーバー名がないときに使う。
    public init(acct: String, localServer: String) {
        let parts = acct.split(separator: "@", maxSplits: 1)
        username = parts.first.map(String.init) ?? acct
        server = parts.count > 1 ? String(parts[1]) : localServer
    }

    /// `acct`のサーバーの部分。同じサーバーのユーザーの`acct`にはないのでnil。
    public static func domain(ofAcct acct: String) -> String? {
        let parts = acct.split(separator: "@", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : nil
    }

    /// 2つのドメインが、同じサーバーかもしれないか。忘れすぎてよいところ（保持している関係を忘れるなど）で使う。
    /// Mastodonは国際化ドメインを、`acct`ではUnicode（`Account#pretty_acct`）、ドメインのブロックではPunycodeで書くので、文字のままでは比べられない。
    /// Punycodeに直さず、どちらも国際化ドメインなら同じかもしれないとみなす。
    public static func mayBeSameDomain(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased() || (isInternationalized(a) && isInternationalized(b))
    }

    private static func isInternationalized(_ domain: String) -> Bool {
        !domain.unicodeScalars.allSatisfy(\.isASCII) || domain.lowercased().split(separator: ".").contains { $0.hasPrefix("xn--") }
    }

    /// `@username@domain`の形。
    public var handle: String { "@\(username)@\(server)" }

    /// `username@domain`の形。ログインしているアカウントによらず、同じ人を同じ文字で指す。
    public var fullAcct: String { "\(username)@\(server)" }

    public func text(of part: UserHandlePart) -> String {
        switch part {
        case .handle: handle
        case .username: username
        case .server: server
        }
    }
}

extension Account {
    /// `acct`が`handle`（`user@domain`）と同じ人か。大文字と小文字は区別しない。文字のままのハンドルで検索した結果が、書かれた人かを確かめるのに使う。
    /// `resolveAccount`は完全に一致する人がいないと似た名前の人を返すことがあり、違う人のプロフィールを開かないため。
    /// 自分のサーバーの人は`localServer`（ログインに使ったサーバー）で補って比べる。ハンドルのサーバー名とウェブのサーバーが別の名前のサーバーで、ウェブの名前のほうで書かれたハンドルは、一致せず見つからなかったものとして扱う。
    /// 別の人を開くより、見つからないと知らせるほうを選ぶ。
    /// 国際化ドメインのサーバーは、`acct`がUnicodeの形で返り、ハンドルは`xn--`の形で書かれることがあるので、サーバー名はASCIIの形にそろえ、ポートも含めて比べる。
    public func hasHandle(_ handle: String, localServer: String) -> Bool {
        let account = UserHandle(acct: acct, localServer: localServer)
        let written = UserHandle(acct: handle, localServer: localServer)
        guard account.username.lowercased() == written.username.lowercased(),
              let accountServer = Self.asciiServer(account.server),
              let writtenServer = Self.asciiServer(written.server) else { return false }
        return accountServer == writtenServer
    }

    private static func asciiServer(_ server: String) -> String? {
        guard let url = URL(string: "https://\(server)"), let host = url.host(percentEncoded: false),
              url.user == nil, url.password == nil, url.path().isEmpty, url.query() == nil, url.fragment() == nil else { return nil }
        return "\(host.lowercased()):\(url.port.map(String.init) ?? "")"
    }
}
