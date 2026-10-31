public import Foundation

/// サーバーの管理者が出すお知らせ。決まりはdocs/announcements.mdにある。
/// https://docs.joinmastodon.org/entities/Announcement/
public struct Announcement: Decodable, Hashable, Sendable, Identifiable {
    public typealias ID = String

    public let id: ID
    /// 本文のHTML。
    public let content: String
    /// 期間の始まりと終わり。どちらも付くか、どちらも付かない。
    public let startsAt: Date?
    public let endsAt: Date?
    /// 期間を日付だけで表すか。期間がなければ偽。
    public let allDay: Bool
    public let publishedAt: Date
    /// 自分が既読にしたか。ストリーミングで届いたお知らせには入っていないのでnil。
    public var read: Bool?
    public let mentions: [Mention]
    /// 本文でリンクした投稿。リンクを押したとき、URLからスレッドを開く投稿を探すのに使う。
    public let statuses: [LinkedStatus]
    public let tags: [Tag]
    public let emojis: [CustomEmoji]
    public var reactions: [AnnouncementReaction]
    /// サーバーがリアクションを許しているか。Mastodon 5.0で増えた値で、返さないサーバーでは許しているものとする。
    public let reactionsAllowed: Bool

    /// 本文でリンクした投稿。
    public struct LinkedStatus: Hashable, Sendable {
        public let id: Status.ID
        public let url: URL?

        public init(id: Status.ID, url: URL?) {
            self.id = id
            self.url = url
        }
    }

    public init(
        id: ID,
        content: String,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        allDay: Bool = false,
        publishedAt: Date,
        read: Bool? = false,
        mentions: [Mention] = [],
        statuses: [LinkedStatus] = [],
        tags: [Tag] = [],
        emojis: [CustomEmoji] = [],
        reactions: [AnnouncementReaction] = [],
        reactionsAllowed: Bool = true
    ) {
        self.id = id
        self.content = content
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.allDay = allDay
        self.publishedAt = publishedAt
        self.read = read
        self.mentions = mentions
        self.statuses = statuses
        self.tags = tags
        self.emojis = emojis
        self.reactions = reactions
        self.reactionsAllowed = reactionsAllowed
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, startsAt, endsAt, allDay, publishedAt, read, mentions, statuses, tags, emojis, reactions, reactionsAllowed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        // 期間は日時を添えるだけなので、読めなければ公開した日時を出す。
        startsAt = container.decodeLossyIfPresent(Date.self, forKey: .startsAt)
        endsAt = container.decodeLossyIfPresent(Date.self, forKey: .endsAt)
        allDay = container.decodeLossyIfPresent(Bool.self, forKey: .allDay) ?? false
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        read = container.decodeLossyIfPresent(Bool.self, forKey: .read)
        mentions = try container.decodeLossyArray(Mention.self, forKey: .mentions)
        statuses = try container.decodeLossyArray(LinkedStatus.self, forKey: .statuses)
        tags = try container.decodeLossyArray(Tag.self, forKey: .tags)
        emojis = try container.decodeLossyArray(CustomEmoji.self, forKey: .emojis)
        reactions = try container.decodeLossyArray(AnnouncementReaction.self, forKey: .reactions)
        reactionsAllowed = container.decodeLossyIfPresent(Bool.self, forKey: .reactionsAllowed) ?? true
    }

    /// 並べるときの日時。サーバーと同じく、期間の始まりがあればそれを、なければ公開した日時を使う。
    public var sortDate: Date { startsAt ?? publishedAt }

    /// まだ既読にしていない。ストリーミングで新しく届いたお知らせも未読とする。
    public var isUnread: Bool { read != true }
}

extension Announcement.LinkedStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Status.ID.self, forKey: .id)
        url = container.decodeURL(.destination, forKey: .url)
    }
}

/// お知らせに付いたリアクション。
/// https://docs.joinmastodon.org/entities/Reaction/
public struct AnnouncementReaction: Decodable, Hashable, Sendable {
    /// Unicodeの絵文字か、カスタム絵文字のショートコード。
    public let name: String
    public var count: Int
    /// 自分がしたか。ストリーミングで届いたものには入っていないのでnil。
    public var me: Bool?
    /// カスタム絵文字の画像。Unicodeの絵文字ではnil。
    public let url: URL?
    public let staticUrl: URL?

    public init(name: String, count: Int, me: Bool?, url: URL? = nil, staticUrl: URL? = nil) {
        self.name = name
        self.count = count
        self.me = me
        self.url = url
        self.staticUrl = staticUrl
    }

    private enum CodingKeys: String, CodingKey {
        case name, count, me, url, staticUrl
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        count = try container.decodeCount(forKey: .count)
        me = container.decodeLossyIfPresent(Bool.self, forKey: .me)
        url = container.decodeURL(.media, forKey: .url)
        staticUrl = container.decodeURL(.media, forKey: .staticUrl)
    }

    /// カスタム絵文字なら、本文の絵文字と同じ部品で描くための絵文字。
    public var customEmoji: CustomEmoji? {
        url.map { CustomEmoji(shortcode: name, url: $0, staticUrl: staticUrl ?? $0) }
    }

    /// 出す数。サーバーの数が自分のリアクションを含まない値で届いても、自分がしているなら1と出す。
    public var displayedCount: Int { me == true ? max(count, 1) : count }
}

/// ストリーミングで届いた、リアクションの数の変化。
/// https://docs.joinmastodon.org/methods/streaming/#events-1
public struct AnnouncementReactionUpdate: Decodable, Hashable, Sendable {
    public let announcementID: Announcement.ID
    public let name: String
    public let count: Int
    public let url: URL?
    public let staticUrl: URL?

    public init(announcementID: Announcement.ID, name: String, count: Int, url: URL? = nil, staticUrl: URL? = nil) {
        self.announcementID = announcementID
        self.name = name
        self.count = count
        self.url = url
        self.staticUrl = staticUrl
    }

    private enum CodingKeys: String, CodingKey {
        case announcementId, name, count, url, staticUrl
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        announcementID = try container.decode(Announcement.ID.self, forKey: .announcementId)
        name = try container.decode(String.self, forKey: .name)
        count = try container.decodeCount(forKey: .count)
        url = container.decodeURL(.media, forKey: .url)
        staticUrl = container.decodeURL(.media, forKey: .staticUrl)
    }
}
