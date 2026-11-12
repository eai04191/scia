/// 自分の投稿を誰が引用できるか。Mastodonが受け付ける3つ。決まりは`docs/quote.md`の「引用できる人を決める」。
/// https://docs.joinmastodon.org/methods/statuses/#create
public enum QuotePolicy: String, Sendable, Hashable, CaseIterable {
    case `public`
    case followers
    case nobody

    public var title: String {
        switch self {
        case .public: "誰でも"
        case .followers: "フォロワーのみ"
        case .nobody: "自分のみ"
        }
    }

    public var symbolName: String {
        switch self {
        case .public: "quote.bubble"
        case .followers: "person.2"
        case .nobody: "person"
        }
    }

    /// 既定と違う値を選んでいることを示すバッジの記号。
    public static let badgeSymbolName = "quote.opening"

    /// この公開範囲の投稿では、選んだ値によらず、サーバーがいつも`nobody`にする。
    public static func isFixed(by visibility: Status.Visibility) -> Bool {
        switch visibility {
        case .private, .direct: true
        case .public, .unlisted, .other: false
        }
    }

    /// 選べない理由。選べる公開範囲ではnil。
    public static func fixedReason(for visibility: Status.Visibility) -> String? {
        switch visibility {
        case .private: "フォロワーのみの投稿は、ほかの人が引用できません"
        case .direct: "メンションした相手のみの投稿は、ほかの人が引用できません"
        case .public, .unlisted, .other: nil
        }
    }

    /// `visibility`で投稿したときに、実際に付く値。
    public func effective(for visibility: Status.Visibility) -> QuotePolicy {
        Self.isFixed(by: visibility) ? .nobody : self
    }
}

extension QuoteApproval {
    /// 投稿に付いている、引用できる人。公式のWebクライアントと同じく、`automatic`の先頭から読み、3つのどれでもなければ`nobody`にする。
    /// https://github.com/mastodon/mastodon/blob/v4.5.0/app/javascript/mastodon/reducers/compose.js
    public var policy: QuotePolicy {
        automatic.first.flatMap(QuotePolicy.init(rawValue:)) ?? .nobody
    }
}
