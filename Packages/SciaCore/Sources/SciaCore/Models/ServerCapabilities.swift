/// サーバーの、Mastodonにない機能の有無。Fedibirdの拡張の`fedibird_capabilities`から決める。
public struct ServerCapabilities: Equatable, Sendable {
    /// 投稿への絵文字のリアクションに対応しているか（docs/emoji-reaction.md）。
    public var supportsEmojiReactions: Bool
    /// ローカルのタイムラインを読めるか。Fedibirdは`timeline_no_local`を返し、ローカルのタイムラインをRESTでは空で返し、ストリーミングでは購読を断る（docs/tabs.md）。
    public var hasLocalTimeline: Bool

    /// Mastodonと同じ。読めていないうちと、読めなかったときに使う。
    public static let mastodon = ServerCapabilities(supportsEmojiReactions: false, hasLocalTimeline: true)

    public init(supportsEmojiReactions: Bool, hasLocalTimeline: Bool) {
        self.supportsEmojiReactions = supportsEmojiReactions
        self.hasLocalTimeline = hasLocalTimeline
    }

    public init(fedibirdCapabilities: [String]) {
        self.init(
            supportsEmojiReactions: fedibirdCapabilities.contains("emoji_reaction"),
            hasLocalTimeline: !fedibirdCapabilities.contains("timeline_no_local")
        )
    }
}
