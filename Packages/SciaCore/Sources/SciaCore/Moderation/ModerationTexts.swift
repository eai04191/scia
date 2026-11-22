/// ミュートしたユーザー、ブロックしたユーザー、ブロックしたドメインの画面の文言。決まりはdocs/moderation-lists.mdにある。
public enum ModerationTexts {
    public static let mutedAccounts = "ミュートしたユーザー"
    public static let blockedAccounts = "ブロックしたユーザー"
    public static let blockedDomains = "ブロックしたドメイン"

    public static let noBlockedDomains = "ブロックしているドメインはありません"
    /// ドメインを入れてブロックするアラートの見出しと、右上のボタンの名前。
    public static let blockDomain = "ドメインをブロック"
    /// ドメインをブロックする前に確かめる本文。ユーザーのメニューと、ドメインを入れるアラートで同じ文言を使う。
    public static let blockDomainMessage = "このサーバーの人の投稿と通知が表示されなくなり、このサーバーの人とのお互いのフォローが外れます。"
    public static let domainPlaceholder = "ドメイン"
    public static let block = "ブロック"
    public static let unblock = "ブロックを解除"
    public static let blockFailed = "ドメインをブロックできませんでした"
    public static let unblockFailed = "ドメインのブロックを解除できませんでした"
    public static let loadMoreFailed = "続きを読み込めませんでした"
}

extension AccountListKind {
    /// 行を左へスワイプして出す、リストから外す操作の名前。外せないリストではnil。
    public var removalTitle: String? {
        switch self {
        case .listMembers: TimelineScreenTexts.removeAccount
        case .mutes: "ミュートを解除"
        case .blocks: ModerationTexts.unblock
        case .favouritedBy, .rebloggedBy, .emojiReactionedBy, .followers, .following, .endorsements: nil
        }
    }

    /// 行を外すときに送る、相手との関係の変更。関係で決まらないリストではnil。
    public var removalChange: UserRelationChange? {
        switch self {
        case .mutes: .unmute
        case .blocks: .unblock
        case .favouritedBy, .rebloggedBy, .emojiReactionedBy, .followers, .following, .listMembers, .endorsements: nil
        }
    }

    /// 関係が変わったあとに、その人がまだこのリストに入るか。関係で決まらないリストではnil。
    /// スワイプでもユーザーのメニューでも、解除したら行を消すために使う。
    public func contains(_ relationship: Relationship) -> Bool? {
        switch self {
        case .mutes: relationship.muting
        case .blocks: relationship.blocking
        case .favouritedBy, .rebloggedBy, .emojiReactionedBy, .followers, .following, .listMembers, .endorsements: nil
        }
    }
}
