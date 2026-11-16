/// サーバーの、Mastodonにない機能の有無。Fedibirdの拡張の`fedibird_capabilities`と`feature_quote`から決める。
public struct ServerCapabilities: Equatable, Sendable {
    /// 投稿への絵文字のリアクションに対応しているか（docs/emoji-reaction.md）。
    public var supportsEmojiReactions: Bool
    /// ローカルのタイムラインを読めるか。Fedibirdは`timeline_no_local`を返し、ローカルのタイムラインをRESTでは空で返し、ストリーミングでは購読を断る（docs/tabs.md）。
    public var hasLocalTimeline: Bool
    /// 引用の決まり（docs/quote.md）。
    public var quotes: QuoteRules
    /// 絵文字の個人セットを読めるか（docs/personal-emoji-set.md）。
    public var supportsPersonalEmojiSets: Bool

    /// Mastodonと同じ。読めていないうちと、読めなかったときに使う。
    public static let mastodon = ServerCapabilities(supportsEmojiReactions: false, hasLocalTimeline: true)

    public init(supportsEmojiReactions: Bool, hasLocalTimeline: Bool, quotes: QuoteRules = .mastodon, supportsPersonalEmojiSets: Bool = false) {
        self.supportsEmojiReactions = supportsEmojiReactions
        self.hasLocalTimeline = hasLocalTimeline
        self.quotes = quotes
        self.supportsPersonalEmojiSets = supportsPersonalEmojiSets
    }

    /// - Parameter featureQuote: `api/v1/instance`の`feature_quote`。Fedibirdの形の引用に対応しているサーバーがtrueを返す。
    public init(fedibirdCapabilities: [String], featureQuote: Bool = false) {
        self.init(
            supportsEmojiReactions: fedibirdCapabilities.contains("emoji_reaction"),
            hasLocalTimeline: !fedibirdCapabilities.contains("timeline_no_local"),
            quotes: featureQuote ? .fedibird : .mastodon,
            supportsPersonalEmojiSets: fedibirdCapabilities.contains("personal_emoji_sets")
        )
    }
}
