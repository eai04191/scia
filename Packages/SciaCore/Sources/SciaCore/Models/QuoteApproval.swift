/// 投稿を誰が引用できるかと、自分が引用できるか。引用の項目の出し方は`docs/quote.md`の「引用して投稿する」。
/// https://docs.joinmastodon.org/entities/QuoteApproval/
public struct QuoteApproval: Codable, Hashable, Sendable {
    /// 引用すると、すぐに認められる人。`public`、`followers`、`following`、`unsupported_policy`などが届く。知らない値もそのまま持つ。
    public let automatic: [String]
    /// 引用すると、投稿者が認めるまで待つ人。値は`automatic`と同じ。
    public let manual: [String]
    /// 届いたままの`current_user`。
    public let currentUser: String
    /// `current_user`が自分について決めた値か。公開とハッシュタグのストリーミングは、ログインしていない人向けの形で配られ、
    /// `current_user`がいつも`denied`になるため、そこで届いたものはfalseにする。
    /// https://github.com/mastodon/mastodon/blob/main/app/services/fan_out_on_write_service.rb
    public private(set) var isCurrentUserKnown = true

    public init(automatic: [String] = [], manual: [String] = [], currentUser: String) {
        self.automatic = automatic
        self.manual = manual
        self.currentUser = currentUser
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automatic = (try? container.decodeIfPresent([String].self, forKey: .automatic)) ?? []
        manual = (try? container.decodeIfPresent([String].self, forKey: .manual)) ?? []
        currentUser = try container.decode(String.self, forKey: .currentUser)
    }

    /// ログインしていない人向けに届いたもの。`current_user`を当てにしない。
    func forAnonymousViewer() -> QuoteApproval {
        var approval = self
        approval.isCurrentUserKnown = false
        return approval
    }

    /// 自分が引用できるか。
    public var availability: QuoteAvailability {
        guard isCurrentUserKnown else { return .unverified }
        return switch currentUser {
        case "automatic": .automatic
        case "manual": .manual
        // `unknown`は、ドキュメントの勧めどおり`denied`として扱う。知らない値も同じにする。
        default: .denied(followersOnly: (automatic + manual).contains("followers"))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case automatic, manual, currentUser
    }
}

/// 自分が投稿を引用できるか。
public enum QuoteAvailability: Hashable, Sendable {
    /// 引用でき、すぐに認められる。
    case automatic
    /// 引用できるが、投稿者が認めるまで表示されない。
    case manual
    /// 引用できない。
    /// - Parameter followersOnly: 投稿者のフォロワーなら引用できる。理由の文言を分けるために使う。
    case denied(followersOnly: Bool)
    /// ログインしていない人向けに届いたため、自分が引用できるか分からない。投稿を読み直して確かめる。
    case unverified

    /// 引用の項目を押せる。分からないときも押せるようにし、押してから確かめる。
    public var canQuote: Bool {
        switch self {
        case .automatic, .manual, .unverified: true
        case .denied: false
        }
    }
}
