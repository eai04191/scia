/// 自分と相手のアカウントの関係。Sciaで使う項目だけを読む。
/// https://docs.joinmastodon.org/entities/Relationship/
public struct Relationship: Codable, Hashable, Sendable {
    /// 相手のアカウントのID。
    public let id: String
    public let following: Bool
    public let followedBy: Bool
    /// フォローの承認を待っている。
    public let requested: Bool
    public let blocking: Bool
    public let blockedBy: Bool
    public let muting: Bool

    public init(id: String, following: Bool = false, followedBy: Bool = false, requested: Bool = false, blocking: Bool = false, blockedBy: Bool = false, muting: Bool = false) {
        self.id = id
        self.following = following
        self.followedBy = followedBy
        self.requested = requested
        self.blocking = blocking
        self.blockedBy = blockedBy
        self.muting = muting
    }
}
