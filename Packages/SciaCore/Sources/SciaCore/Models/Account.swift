public import Foundation

public struct Account: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let acct: String
    /// プレーンテキスト。`:shortcode:`のカスタム絵文字を含むことがある。
    public let displayName: String
    public let avatar: URL
    /// 表示名とプロフィールで使われるカスタム絵文字。
    public let emojis: [CustomEmoji]

    public init(id: String, username: String, acct: String, displayName: String, avatar: URL, emojis: [CustomEmoji] = []) {
        self.id = id
        self.username = username
        self.acct = acct
        self.displayName = displayName
        self.avatar = avatar
        self.emojis = emojis
    }

    /// 表示名が空ならユーザー名を使う。
    public var displayNameOrUsername: String {
        displayName.isEmpty ? username : displayName
    }
}
