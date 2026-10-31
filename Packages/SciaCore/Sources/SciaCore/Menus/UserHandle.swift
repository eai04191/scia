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

    public func text(of part: UserHandlePart) -> String {
        switch part {
        case .handle: handle
        case .username: username
        case .server: server
        }
    }
}
