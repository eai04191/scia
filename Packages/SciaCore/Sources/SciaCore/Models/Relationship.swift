/// 自分と相手のアカウントの関係。Sciaで使う項目だけを読む。
/// https://docs.joinmastodon.org/entities/Relationship/
public struct Relationship: Codable, Hashable, Sendable {
    /// 相手のアカウントのID。
    public let id: String
    public let following: Bool
    /// フォローしている相手のブーストを、ホームに流している。
    public let showingReblogs: Bool
    /// 相手が投稿したら通知を受け取る。
    public let notifying: Bool
    public let followedBy: Bool
    /// フォローの承認を待っている。
    public let requested: Bool
    public let blocking: Bool
    public let blockedBy: Bool
    public let muting: Bool
    /// ミュートで、相手からの通知も隠している。
    public let mutingNotifications: Bool

    public init(
        id: String,
        following: Bool = false,
        showingReblogs: Bool = true,
        notifying: Bool = false,
        followedBy: Bool = false,
        requested: Bool = false,
        blocking: Bool = false,
        blockedBy: Bool = false,
        muting: Bool = false,
        mutingNotifications: Bool = false
    ) {
        self.id = id
        self.following = following
        self.showingReblogs = showingReblogs
        self.notifying = notifying
        self.followedBy = followedBy
        self.requested = requested
        self.blocking = blocking
        self.blockedBy = blockedBy
        self.muting = muting
        self.mutingNotifications = mutingNotifications
    }
}
