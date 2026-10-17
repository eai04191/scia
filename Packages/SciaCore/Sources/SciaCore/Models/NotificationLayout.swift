extension MastodonNotification {
    /// 通知の行の組み方。通知と投稿では主役が違うため、種類ごとに、対象の投稿をどう出すかを決める。
    public enum Layout: Equatable, Sendable {
        /// ホームの投稿と同じ見た目にし、その上に誰が何をしたかの行を1行足す。対象の投稿は相手が書いたもので、読む必要がある。
        case post
        /// 誰が何をしたかの行を主役にし、対象の投稿を控えめに再掲する。お気に入りやブーストの通知は、自分の投稿の再掲になる。
        /// - Parameter showsPollResults: 投票を結果の形で足す。投票の終了の通知は、結果を知るためのものなので。
        case quoted(showsPollResults: Bool)
        /// 誰が何をしたかの行だけを出す。
        case headerOnly
    }

    /// 対象の投稿が届いていない通知は、種類によらず誰が何をしたかの行だけにする。
    public var layout: Layout {
        guard status != nil else { return .headerOnly }
        return switch type {
        case .mention, .status, .quote: .post
        case .favourite, .reblog, .update, .quotedUpdate: .quoted(showsPollResults: false)
        case .poll: .quoted(showsPollResults: true)
        case .follow, .followRequest, .other: .headerOnly
        }
    }
}
