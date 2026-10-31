public import Foundation

/// プロフィールのハンドルを押したときのメニューの、コピーの項目。決まりはdocs/profile.mdの「ハンドル」にある。
public struct HandleCopyItem: Equatable, Sendable {
    public enum Kind: Sendable {
        /// `@user@domain`。
        case handle
        /// `user`。`@`は付けない。
        case username
        /// `domain`。
        case server
        /// サーバーが返すプロフィールのURL。
        case link
    }

    public let kind: Kind
    /// コピーする文字。項目のサブテキストにもそのまま出す。
    public let value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    /// メニューに並べる順の項目。プロフィールのURLがなければ、リンクは出さない。
    /// - Parameters:
    ///   - acct: Mastodonの`acct`。同じサーバーの人ではサーバー名を含まない。
    ///   - localServer: ログインしているサーバーの名前。`acct`にサーバー名がないときに使う。
    public static func items(acct: String, url: URL?, localServer: String) -> [HandleCopyItem] {
        let parts = acct.split(separator: "@", maxSplits: 1)
        let username = parts.first.map(String.init) ?? acct
        let server = parts.count > 1 ? String(parts[1]) : localServer
        var items = [
            HandleCopyItem(kind: .handle, value: "@\(username)@\(server)"),
            HandleCopyItem(kind: .username, value: username),
            HandleCopyItem(kind: .server, value: server),
        ]
        if let url {
            items.append(HandleCopyItem(kind: .link, value: url.absoluteString))
        }
        return items
    }
}
