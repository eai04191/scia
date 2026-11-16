/// 投稿への絵文字のリアクションの、サーバーごとのAPIの形（docs/emoji-reaction.mdの「対象のサーバー」）。
public enum EmojiReactionStyle: Hashable, Sendable {
    /// FedibirdとkmyblueのAPI。
    case fedibird
    /// Chuckya（glitch-socの絵文字のリアクション）のAPI。`react/:name`と`unreact/:name`で付け外しし、投稿の`reactions`を読む。
    case chuckya
    /// Firefishから分かれたサーバー（Sharkey、Catodon、Iceshrimp）のAPI。経路と読む値はChuckyaと同じで、カスタム絵文字の名前の書き方が違う。
    case firefish
    /// PleromaとAkkomaのAPI。`pleroma/statuses/:id/reactions/:emoji`で付け外しし、投稿の`pleroma.emoji_reactions`を読む。
    case pleroma

    /// その絵文字でリアクションした人を読めるか。
    public var listsReactedAccounts: Bool { self == .fedibird || self == .pleroma }

    /// お気に入りとリアクションの結果を、応答の投稿のリアクションの列とお気に入りの数と状態から丸ごと取り込むか。
    /// ChuckyaとFirefishの形では、サーバーによって、お気に入りがリアクションとして保存されたり、付けたリアクションが前のものと置き換わったり、上限で断られたりする。
    /// どれになるかを手元で決めず、応答に任せる。
    public var settlesFromResponse: Bool { self == .chuckya || self == .firefish }

    /// ほかのサーバーのカスタム絵文字でリアクションできないか。Firefishの形のサーバーは、ログインしているサーバーにない絵文字を既定の絵文字に替えて付ける。
    public var refusesRemoteEmojis: Bool { self == .firefish }

    /// ログインしているサーバーのカスタム絵文字のリアクションに、画像のURLが付かないことがあるか。
    public var omitsLocalEmojiImages: Bool { self == .firefish }
}

/// サーバーの、Mastodonにない機能の有無。Fedibirdの拡張の`fedibird_capabilities`と`feature_quote`、`configuration.reactions`、Chuckyaの`api_versions`、Pleromaの`pleroma.metadata.features`から決める。
public struct ServerCapabilities: Equatable, Sendable {
    /// 投稿への絵文字のリアクションのAPIの形。対応していなければnil（docs/emoji-reaction.md）。
    public var emojiReactions: EmojiReactionStyle?
    /// 投稿への絵文字のリアクションに対応しているか。trueを入れると、形が決まっていなければFedibirdの形にする。
    public var supportsEmojiReactions: Bool {
        get { emojiReactions != nil }
        set { emojiReactions = newValue ? emojiReactions ?? .fedibird : nil }
    }
    /// ローカルのタイムラインを読めるか。Fedibirdは`timeline_no_local`を返し、ローカルのタイムラインをRESTでは空で返し、ストリーミングでは購読を断る（docs/tabs.md）。
    public var hasLocalTimeline: Bool
    /// 引用の決まり（docs/quote.md）。
    public var quotes: QuoteRules
    /// 絵文字の個人セットを読めるか（docs/personal-emoji-set.md）。
    public var supportsPersonalEmojiSets: Bool

    /// Mastodonと同じ。読めていないうちと、読めなかったときに使う。
    public static let mastodon = ServerCapabilities(supportsEmojiReactions: false, hasLocalTimeline: true)

    public init(supportsEmojiReactions: Bool, hasLocalTimeline: Bool, quotes: QuoteRules = .mastodon, supportsPersonalEmojiSets: Bool = false) {
        self.init(emojiReactions: supportsEmojiReactions ? .fedibird : nil, hasLocalTimeline: hasLocalTimeline, quotes: quotes, supportsPersonalEmojiSets: supportsPersonalEmojiSets)
    }

    public init(emojiReactions: EmojiReactionStyle?, hasLocalTimeline: Bool, quotes: QuoteRules = .mastodon, supportsPersonalEmojiSets: Bool = false) {
        self.emojiReactions = emojiReactions
        self.hasLocalTimeline = hasLocalTimeline
        self.quotes = quotes
        self.supportsPersonalEmojiSets = supportsPersonalEmojiSets
    }

    /// - Parameters:
    ///   - featureQuote: `api/v1/instance`の`feature_quote`。Fedibirdの形の引用に対応しているサーバーがtrueを返す。
    ///   - pleromaFeatures: `api/v1/instance`の`pleroma.metadata.features`。`pleroma_emoji_reactions`があればPleromaの形。
    ///     Iceshrimp.NETはこの値も`configuration.reactions`も返す。実物で確かめてある`react/:name`の形を優先する。
    ///   - reactEndpoints: `react/:name`と`unreact/:name`で付け外しするサーバーなら、その形。`api/v1/instance`に`configuration.reactions`があるサーバーで、
    ///     `api/v2/instance`の`api_versions`に`chuckya`があればChuckya、なければFirefishの形。Fedibirdは`configuration.emoji_reactions`で返すので、ここには入らない。
    public init(fedibirdCapabilities: [String], featureQuote: Bool = false, reactEndpoints: EmojiReactionStyle? = nil, pleromaFeatures: [String] = []) {
        let emojiReactions: EmojiReactionStyle? = if fedibirdCapabilities.contains("emoji_reaction") {
            .fedibird
        } else if let reactEndpoints {
            reactEndpoints
        } else if pleromaFeatures.contains("pleroma_emoji_reactions") {
            .pleroma
        } else {
            nil
        }
        self.init(
            emojiReactions: emojiReactions,
            hasLocalTimeline: !fedibirdCapabilities.contains("timeline_no_local"),
            quotes: featureQuote ? .fedibird : .mastodon,
            supportsPersonalEmojiSets: fedibirdCapabilities.contains("personal_emoji_sets")
        )
    }
}
