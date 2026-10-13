public import Foundation

public struct Account: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let acct: String
    public let displayName: String
    public let avatar: URL

    public init(id: String, username: String, acct: String, displayName: String, avatar: URL) {
        self.id = id
        self.username = username
        self.acct = acct
        self.displayName = displayName
        self.avatar = avatar
    }
}
