/// サーバーの、Mastodonにない機能の有無。Fedibirdの拡張の`fedibird_capabilities`から決める。
public struct ServerCapabilities: Equatable, Sendable {
    /// 投稿への絵文字のリアクションに対応しているか（docs/emoji-reaction.md）。
    public var supportsEmojiReactions: Bool

    /// Mastodonと同じ。読めていないうちと、読めなかったときに使う。
    public static let mastodon = ServerCapabilities(supportsEmojiReactions: false)

    public init(supportsEmojiReactions: Bool) {
        self.supportsEmojiReactions = supportsEmojiReactions
    }

    public init(fedibirdCapabilities: [String]) {
        self.init(supportsEmojiReactions: fedibirdCapabilities.contains("emoji_reaction"))
    }
}
