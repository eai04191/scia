extension MastodonNotification {
    /// 通知の行の組み方。通知と投稿では主役が違うため、種類ごとに、対象の投稿をどう出すかを決める。
    public enum Layout: Equatable, Sendable {
        /// ホームの投稿と同じ見た目にし、その上に誰が何をしたかの行を1行足す。対象の投稿は相手が書いたもの（投票の終了は自分の投稿も）で、操作も投稿と同じにする。
        case post
        /// 誰が何をしたかの行を主役にし、対象の自分の投稿を控えめに再掲する。
        case quoted
        /// 誰が何をしたかの行だけを出す。
        case headerOnly
    }

    /// 対象の投稿が届いていない通知は、種類によらず誰が何をしたかの行だけにする。
    public var layout: Layout {
        guard status != nil else { return .headerOnly }
        return switch type {
        case .mention, .status, .quote, .update, .poll: .post
        // 引用した投稿の編集は、編集された相手の投稿ではなく、それを引用した自分の投稿が対象になる。
        case .favourite, .reblog, .emojiReaction, .quotedUpdate: .quoted
        case .follow, .followRequest, .other: .headerOnly
        }
    }
}
