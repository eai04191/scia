public import Foundation

/// https://docs.joinmastodon.org/entities/Account/
public struct Account: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let acct: String
    /// プレーンテキスト。`:shortcode:`のカスタム絵文字を含むことがある。
    public let displayName: String
    /// アニメーションすることがある。画像のURLは、サーバーによって空で返るため、読めなければnil。
    public let avatar: URL?
    /// アニメーションしない版。
    public let avatarStatic: URL?
    public let header: URL?
    public let headerStatic: URL?
    /// アイコンの代替テキスト。Mastodon 4.4から。古いサーバーは返さないため、なければnil。
    public let avatarDescription: String?
    /// ヘッダー画像の代替テキスト。`avatarDescription`と同じく、なければnil。
    public let headerDescription: String?
    /// 自己紹介。Mastodonが返すHTML文字列。
    public let note: String
    /// プロフィールのページ。リモートのアカウントなら、元のサーバーのページ。読めなければnil。
    public let url: URL?
    /// プロフィールの補足情報。
    public let fields: [Field]
    /// 表示名とプロフィールで使われるカスタム絵文字。
    public let emojis: [CustomEmoji]
    /// フォローに承認が要る。
    public let locked: Bool
    public let bot: Bool
    public let followersCount: Int
    public let followingCount: Int
    public let statusesCount: Int

    /// https://docs.joinmastodon.org/entities/Account/#Field
    public struct Field: Codable, Hashable, Sendable {
        public let name: String
        /// Mastodonが返すHTML文字列。
        public let value: String
        /// 値のリンク先に、このアカウントへのリンクがあると確かめられた日時。
        public let verifiedAt: Date?

        public init(name: String, value: String, verifiedAt: Date? = nil) {
            self.name = name
            self.value = value
            self.verifiedAt = verifiedAt
        }
    }

    /// 省いた画像のURLは`avatar`で埋める。APIからは必ず届く項目で、省けるのはテストとダミー投稿で書く手間を減らすため。
    public init(
        id: String,
        username: String,
        acct: String,
        displayName: String,
        avatar: URL?,
        avatarStatic: URL? = nil,
        header: URL? = nil,
        headerStatic: URL? = nil,
        avatarDescription: String? = nil,
        headerDescription: String? = nil,
        note: String = "",
        url: URL? = nil,
        fields: [Field] = [],
        emojis: [CustomEmoji] = [],
        locked: Bool = false,
        bot: Bool = false,
        followersCount: Int = 0,
        followingCount: Int = 0,
        statusesCount: Int = 0
    ) {
        self.id = id
        self.username = username
        self.acct = acct
        self.displayName = displayName
        self.avatar = avatar
        self.avatarStatic = avatarStatic ?? avatar
        self.header = header ?? avatar
        self.headerStatic = headerStatic ?? header ?? avatar
        self.avatarDescription = avatarDescription
        self.headerDescription = headerDescription
        self.note = note
        self.url = url ?? avatar
        self.fields = fields
        self.emojis = emojis
        self.locked = locked
        self.bot = bot
        self.followersCount = followersCount
        self.followingCount = followingCount
        self.statusesCount = statusesCount
    }

    /// 画像とプロフィールのURLは、空や不正な値ならnilにする。絵文字と補足情報は、読めない要素を外し、なければ空にする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        acct = try container.decode(String.self, forKey: .acct)
        displayName = try container.decode(String.self, forKey: .displayName)
        avatar = container.decodeURL(.media, forKey: .avatar)
        avatarStatic = container.decodeURL(.media, forKey: .avatarStatic)
        header = container.decodeURL(.media, forKey: .header)
        headerStatic = container.decodeURL(.media, forKey: .headerStatic)
        avatarDescription = try container.decodeIfPresent(String.self, forKey: .avatarDescription)
        headerDescription = try container.decodeIfPresent(String.self, forKey: .headerDescription)
        note = try container.decode(String.self, forKey: .note)
        url = container.decodeURL(.destination, forKey: .url)
        fields = try container.decodeLossyArray(Field.self, forKey: .fields)
        emojis = try container.decodeLossyArray(CustomEmoji.self, forKey: .emojis)
        locked = try container.decode(Bool.self, forKey: .locked)
        bot = try container.decode(Bool.self, forKey: .bot)
        followersCount = try container.decodeCount(forKey: .followersCount)
        followingCount = try container.decodeCount(forKey: .followingCount)
        statusesCount = try container.decodeCount(forKey: .statusesCount)
    }

    /// 表示名が空ならユーザー名を使う。
    public var displayNameOrUsername: String {
        displayName.isEmpty ? username : displayName
    }
}
