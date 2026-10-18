public import Foundation

public struct Status: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let createdAt: Date
    public let account: Account
    /// Mastodonが返すHTML文字列。リッチテキストへの変換は表示層で行う。
    public let content: String
    public let spoilerText: String
    /// 投稿した人が選んだ本文の言語（ISO 639-1の2文字）。選ばれていなければnil。
    public let language: String?
    public let url: URL?
    public let mentions: [Mention]
    public let tags: [Tag]
    /// 本文と注意書きで使われるカスタム絵文字。
    public let emojis: [CustomEmoji]
    public let mediaAttachments: [MediaAttachment]
    /// 添付ファイルを閲覧注意として隠す。
    public let sensitive: Bool
    public let visibility: Visibility
    /// 返信先の投稿のID。
    public let inReplyToId: String?
    public let poll: Poll?
    /// 本文のリンク先から作ったカード。
    public let card: PreviewCard?
    /// 引用。引用していなければnil。
    public let quote: Quote?
    /// 当たった自分のフィルター。ログインせずに読んだときや、Mastodon 4.0より前のサーバーでは返らないため、無ければ空にする。
    public let filtered: [FilterResult]
    /// 最後に編集した日時。編集していなければnil。
    public let editedAt: Date?
    /// 自分がお気に入りに登録している。
    public private(set) var favourited: Bool
    /// 自分がブーストしている。
    public private(set) var reblogged: Bool
    /// 自分がブックマークしている。
    public private(set) var bookmarked: Bool
    public private(set) var favouritesCount: Int
    public private(set) var reblogsCount: Int
    public let repliesCount: Int
    /// ブーストの場合、ブーストされた元の投稿。構造体は自分自身を直接持てないため、参照型の箱に入れる。
    private var reblogBox: StatusBox?

    public init(
        id: String,
        createdAt: Date,
        account: Account,
        content: String,
        spoilerText: String,
        language: String? = nil,
        url: URL?,
        mentions: [Mention] = [],
        tags: [Tag] = [],
        emojis: [CustomEmoji] = [],
        mediaAttachments: [MediaAttachment] = [],
        sensitive: Bool = false,
        visibility: Visibility = .public,
        inReplyToId: String? = nil,
        poll: Poll? = nil,
        card: PreviewCard? = nil,
        quote: Quote? = nil,
        filtered: [FilterResult] = [],
        editedAt: Date? = nil,
        favourited: Bool = false,
        reblogged: Bool = false,
        bookmarked: Bool = false,
        favouritesCount: Int = 0,
        reblogsCount: Int = 0,
        repliesCount: Int = 0,
        reblog: Status? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.account = account
        self.content = content
        self.spoilerText = spoilerText
        self.language = language
        self.url = url
        self.mentions = mentions
        self.tags = tags
        self.emojis = emojis
        self.mediaAttachments = mediaAttachments
        self.sensitive = sensitive
        self.visibility = visibility
        self.inReplyToId = inReplyToId
        self.poll = poll
        self.card = card
        self.quote = quote
        self.filtered = filtered
        self.editedAt = editedAt
        self.favourited = favourited
        self.reblogged = reblogged
        self.bookmarked = bookmarked
        self.favouritesCount = favouritesCount
        self.reblogsCount = reblogsCount
        self.repliesCount = repliesCount
        reblogBox = reblog.map(StatusBox.init)
    }

    /// 自分の操作を表す項目と件数は、ログインせずに読んだときや、サーバーの実装によっては返らないため、無ければ既定値にする。
    /// URLと、メンションなどの配列も、サーバーによって空や欠落で返るため、URLはnil、配列は空にする。
    /// 投票、カード、引用、編集した日時は、読めなくても本文は読めるため、読めなければ記録してnilにする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        account = try container.decode(Account.self, forKey: .account)
        content = try container.decode(String.self, forKey: .content)
        spoilerText = try container.decode(String.self, forKey: .spoilerText)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        url = container.decodeDisplayURL(forKey: .url)
        mentions = try container.decodeLossyArray(Mention.self, forKey: .mentions)
        tags = try container.decodeLossyArray(Tag.self, forKey: .tags)
        emojis = try container.decodeLossyArray(CustomEmoji.self, forKey: .emojis)
        mediaAttachments = try container.decodeLossyArray(MediaAttachment.self, forKey: .mediaAttachments)
        sensitive = try container.decode(Bool.self, forKey: .sensitive)
        visibility = try container.decodeIfPresent(Visibility.self, forKey: .visibility) ?? .public
        inReplyToId = try container.decodeIfPresent(String.self, forKey: .inReplyToId)
        poll = container.decodeLossyIfPresent(Poll.self, forKey: .poll)
        card = container.decodeLossyIfPresent(PreviewCard.self, forKey: .card)
        quote = container.decodeLossyIfPresent(Quote.self, forKey: .quote)
        filtered = try container.decodeLossyArray(FilterResult.self, forKey: .filtered)
        editedAt = container.decodeLossyIfPresent(Date.self, forKey: .editedAt)
        favourited = try container.decodeIfPresent(Bool.self, forKey: .favourited) ?? false
        reblogged = try container.decodeIfPresent(Bool.self, forKey: .reblogged) ?? false
        bookmarked = try container.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
        favouritesCount = try container.decodeIfPresent(Int.self, forKey: .favouritesCount) ?? 0
        reblogsCount = try container.decodeIfPresent(Int.self, forKey: .reblogsCount) ?? 0
        repliesCount = try container.decodeIfPresent(Int.self, forKey: .repliesCount) ?? 0
        reblogBox = try container.decodeIfPresent(StatusBox.self, forKey: .reblogBox)
    }

    public var reblog: Status? { reblogBox?.value }

    /// 画面に出す投稿。ブーストなら元の投稿、そうでなければ自身。
    public var displayed: Status { reblog ?? self }

    /// ブーストした元の投稿を差し替えたもの。元の投稿が編集されたときに使う。
    public func replacingReblog(with reblog: Status) -> Status {
        var status = self
        status.reblogBox = StatusBox(reblog)
        return status
    }

    /// `accountID`のアカウントがブーストできる。フォロワー限定は自分の投稿だけ、ダイレクトはできない。
    public func canBeReblogged(by accountID: String) -> Bool {
        let target = displayed
        return switch target.visibility {
        case .public, .unlisted: true
        case .private: target.account.id == accountID
        case .direct, .other: false
        }
    }

    /// お気に入りの状態を変えたもの。サーバーの結果を待たずに表示へ反映するために使う。
    public func settingFavourited(_ favourited: Bool) -> Status {
        guard favourited != self.favourited else { return self }
        var status = self
        status.favourited = favourited
        status.favouritesCount = max(favouritesCount + (favourited ? 1 : -1), 0)
        return status
    }

    /// お気に入りの状態と件数を`other`に揃えたもの。サーバーの応答のうち、その操作の結果だけを反映するために使う。
    public func adoptingFavourite(of other: Status) -> Status {
        var status = self
        status.favourited = other.favourited
        status.favouritesCount = other.favouritesCount
        return status
    }

    /// ブーストの状態と件数を`other`に揃えたもの。
    public func adoptingReblog(of other: Status) -> Status {
        var status = self
        status.reblogged = other.reblogged
        status.reblogsCount = other.reblogsCount
        return status
    }

    /// ブーストの状態を変えたもの。サーバーの結果を待たずに表示へ反映するために使う。
    public func settingReblogged(_ reblogged: Bool) -> Status {
        guard reblogged != self.reblogged else { return self }
        var status = self
        status.reblogged = reblogged
        status.reblogsCount = max(reblogsCount + (reblogged ? 1 : -1), 0)
        return status
    }

    /// ブックマークの状態を変えたもの。サーバーの結果を待たずに表示へ反映するために使う。
    public func settingBookmarked(_ bookmarked: Bool) -> Status {
        var status = self
        status.bookmarked = bookmarked
        return status
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, account, content, spoilerText, language, url, mentions, tags, emojis, mediaAttachments, sensitive
        case visibility, inReplyToId, poll, card, quote, filtered, editedAt
        case favourited, reblogged, bookmarked, favouritesCount, reblogsCount, repliesCount
        case reblogBox = "reblog"
    }

    /// 公開範囲。
    /// https://docs.joinmastodon.org/entities/Status/#visibility
    public enum Visibility: Hashable, Sendable, Codable {
        case `public`
        /// 公開だが、公開タイムラインには出さない。
        case unlisted
        /// フォロワーだけ。
        case `private`
        /// メンションした相手だけ。
        case direct
        /// サーバー独自の公開範囲（Fedibirdの`limited`など）。
        case other(String)

        /// 届く範囲の広さの順。サーバー独自の公開範囲は、どこまで届くか分からないため最も狭いものとして扱う。
        var openness: Int {
            switch self {
            case .public: 3
            case .unlisted: 2
            case .private: 1
            case .direct, .other: 0
            }
        }

        /// `self`と`other`のうち、届く範囲が狭い方。
        public func narrower(_ other: Visibility) -> Visibility {
            other.openness < openness ? other : self
        }

        public init(rawValue: String) {
            self = switch rawValue {
            case "public": .public
            case "unlisted": .unlisted
            case "private": .private
            case "direct": .direct
            default: .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .public: "public"
            case .unlisted: "unlisted"
            case .private: "private"
            case .direct: "direct"
            case .other(let rawValue): rawValue
            }
        }

        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

final class StatusBox: Codable, Hashable, Sendable {
    let value: Status

    init(_ value: Status) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        value = try Status(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }

    static func == (lhs: StatusBox, rhs: StatusBox) -> Bool {
        lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }
}
