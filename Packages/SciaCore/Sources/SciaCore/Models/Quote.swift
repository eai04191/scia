/// 投稿の中の引用。見せ方は`docs/quote.md`。
///
/// 投稿の`quote`は`Quote`で、引用元の投稿をそのまま持つ。引用元の投稿の`quote`は`ShallowQuote`で、引用元のIDだけを持つ。
/// どちらも同じキーで届くので、1つの型で読む。
/// https://docs.joinmastodon.org/entities/Quote/
/// https://docs.joinmastodon.org/entities/ShallowQuote/
public struct Quote: Codable, Hashable, Sendable {
    /// 引用を出せるかどうか。
    public enum State: Hashable, Sendable {
        /// 引用された人がまだ認めていない。
        case pending
        /// 認めて出せる。
        case accepted
        /// 引用された人が断った。
        case rejected
        /// 一度認めたあとで、引用された人が取り消した。
        case revoked
        /// 引用元の投稿が削除された。
        case deleted
        /// 見る権限がない。知らない値もこれとして扱う（ドキュメントの指示）。
        case unauthorized
        /// 引用元の人をブロックしている。
        case blockedAccount
        /// 引用元の人のドメインをブロックしている。
        case blockedDomain
        /// 引用元の人をミュートしている。
        case mutedAccount

        init(rawValue: String) {
            self = switch rawValue {
            case "pending": .pending
            case "accepted": .accepted
            case "rejected": .rejected
            case "revoked": .revoked
            case "deleted": .deleted
            case "blocked_account": .blockedAccount
            case "blocked_domain": .blockedDomain
            case "muted_account": .mutedAccount
            default: .unauthorized
            }
        }
    }

    /// 届いたままの`state`。
    public let rawState: String
    private let quotedStatusBox: StatusBox?
    /// `ShallowQuote`で届いた、引用元の投稿のID。`Quote`で届いたときは、引用元の投稿のIDを返す。
    public let quotedStatusID: Status.ID?

    public var state: State { State(rawValue: rawState) }

    /// 引用元の投稿。`ShallowQuote`で届いたときと、出せない`state`ではnil。
    public var quotedStatus: Status? { quotedStatusBox?.value }

    public init(state: String, quotedStatus: Status? = nil, quotedStatusID: Status.ID? = nil) {
        rawState = state
        quotedStatusBox = quotedStatus.map(StatusBox.init)
        self.quotedStatusID = quotedStatusID ?? quotedStatus?.id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawState = try container.decode(String.self, forKey: .state)
        // 引用元の投稿が読めなくても、引用があることは残し、出せないときの表示にする。
        quotedStatusBox = container.decodeLossyIfPresent(StatusBox.self, forKey: .quotedStatus)
        quotedStatusID = (try? container.decodeIfPresent(String.self, forKey: .quotedStatusId)) ?? quotedStatusBox?.value.id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawState, forKey: .state)
        try container.encodeIfPresent(quotedStatusBox, forKey: .quotedStatus)
        try container.encodeIfPresent(quotedStatusID, forKey: .quotedStatusId)
    }

    private enum CodingKeys: String, CodingKey {
        case state, quotedStatus, quotedStatusId
    }
}
