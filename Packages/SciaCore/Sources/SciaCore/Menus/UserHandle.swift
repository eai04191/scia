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
    public func hasHandle(_ handle: String, localServer: String) -> Bool {
        UserHandle(acct: acct, localServer: localServer).handle.lowercased() == "@\(handle.lowercased())"
    }
}
