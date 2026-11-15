/// サーバーの引用の決まり。引用できるかの決め方、送り方、取り消せるかが、サーバーの実装で違う。
/// 違いはここに集め、使う側はサーバーの種類を見ずにここに聞く。決まりは`docs/quote.md`の「Fedibirdの形」。
public enum QuoteRules: Hashable, Sendable {
    /// Mastodonの形。引用できるかは、投稿の`quote_approval`で届く。
    /// https://docs.joinmastodon.org/client/quotes/
    case mastodon
    /// Fedibirdの形。承認の仕組みがなく、公開か未収載の投稿だけを引用できる。
    /// fedibird/mastodonの`app/models/status.rb`の`quote_visibility`の検証
    case fedibird

    /// 自分が`status`を引用できるか。ブーストなら元の投稿で決める。引用に対応していないサーバーの投稿ではnil。
    public func availability(of status: Status) -> QuoteAvailability? {
        let target = status.displayed
        switch self {
        case .mastodon:
            return target.quoteApproval?.availability
        case .fedibird:
            switch target.visibility {
            case .public, .unlisted: return .automatic
            case .private, .direct, .other: return .denied(followersOnly: false)
            }
        }
    }

    /// 投稿するときに、引用元のIDを入れるパラメーターの名前。
    var quotedStatusParameter: String {
        switch self {
        case .mastodon: "quoted_status_id"
        case .fedibird: "quote_id"
        }
    }

    /// 自分の投稿への引用を、あとから取り消せるか。
    public var canRevoke: Bool {
        switch self {
        case .mastodon: true
        case .fedibird: false
        }
    }
}
