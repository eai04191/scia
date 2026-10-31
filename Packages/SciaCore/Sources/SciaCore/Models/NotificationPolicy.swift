public import Foundation

/// 通知のフィルタリングの設定。誰からの通知を受け入れ、保留し、無視するか。決まりはdocs/notification-filter.mdにある。
/// https://docs.joinmastodon.org/entities/NotificationPolicy/
public struct NotificationPolicy: Decodable, Hashable, Sendable {
    /// 設定の項目。並びは、設定の画面に並べる順。値は送るときの名前。
    public enum Item: String, CaseIterable, Sendable {
        case notFollowing = "for_not_following"
        case notFollowers = "for_not_followers"
        case newAccounts = "for_new_accounts"
        case privateMentions = "for_private_mentions"
        case limitedAccounts = "for_limited_accounts"
    }

    /// 項目ごとの扱い。
    public enum Value: Hashable, Sendable {
        /// 通知を受け入れる。
        case accept
        /// 保留中の通知に止め置く。
        case filter
        /// サーバーが通知を作らない。あとから見られない。
        case drop
        /// サーバーが返した、Sciaの知らない値。選べない形で出し、送らない。
        case unknown(String)

        /// 設定の画面で選べる値。
        public static let choices: [Value] = [.accept, .filter, .drop]

        init(rawValue: String) {
            self = switch rawValue {
            case "accept": .accept
            case "filter": .filter
            case "drop": .drop
            default: .unknown(rawValue)
            }
        }

        /// 送るときの値。知らない値は送らないのでnil。
        public var rawValue: String? {
            switch self {
            case .accept: "accept"
            case .filter: "filter"
            case .drop: "drop"
            case .unknown: nil
            }
        }
    }

    public private(set) var values: [Item: Value]
    /// 無視していない保留中の通知を送った人の数。サーバーは100で止める。
    public let pendingRequestsCount: Int
    /// 無視していない保留中の通知の数。サーバーは正確でないことがあるとしている。
    public let pendingNotificationsCount: Int

    public init(values: [Item: Value], pendingRequestsCount: Int = 0, pendingNotificationsCount: Int = 0) {
        self.values = values
        self.pendingRequestsCount = pendingRequestsCount
        self.pendingNotificationsCount = pendingNotificationsCount
    }

    public subscript(item: Item) -> Value? {
        get { values[item] }
        set { values[item] = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case forNotFollowing
        case forNotFollowers
        case forNewAccounts
        case forPrivateMentions
        case forLimitedAccounts
        case summary
    }

    private struct Summary: Decodable {
        let pendingRequestsCount: Int
        let pendingNotificationsCount: Int

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pendingRequestsCount = try container.decodeCount(forKey: .pendingRequestsCount)
            pendingNotificationsCount = try container.decodeCount(forKey: .pendingNotificationsCount)
        }

        private enum CodingKeys: String, CodingKey {
            case pendingRequestsCount
            case pendingNotificationsCount
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys: [Item: CodingKeys] = [
            .notFollowing: .forNotFollowing,
            .notFollowers: .forNotFollowers,
            .newAccounts: .forNewAccounts,
            .privateMentions: .forPrivateMentions,
            .limitedAccounts: .forLimitedAccounts,
        ]
        var values: [Item: Value] = [:]
        for item in Item.allCases {
            // 項目がないサーバーでは、その項目を出さない。
            guard let key = keys[item], let raw = try container.decodeIfPresent(String.self, forKey: key) else { continue }
            values[item] = Value(rawValue: raw)
        }
        self.values = values
        let summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
        pendingRequestsCount = summary?.pendingRequestsCount ?? 0
        pendingNotificationsCount = summary?.pendingNotificationsCount ?? 0
    }
}

/// 保留中の通知を送った1人分のまとまり。
/// https://docs.joinmastodon.org/entities/NotificationRequest/
public struct NotificationRequest: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    /// 最後に更新された日時。
    public let updatedAt: Date
    /// 保留した通知を送った人。
    public let account: Account
    /// 保留している通知の数。サーバーは文字列で返す。
    public let notificationsCount: Int
    /// 保留している通知のうち、最も新しい投稿。投稿のない通知だけならnil。
    public let lastStatus: Status?

    public init(id: String, updatedAt: Date, account: Account, notificationsCount: Int, lastStatus: Status? = nil) {
        self.id = id
        self.updatedAt = updatedAt
        self.account = account
        self.notificationsCount = notificationsCount
        self.lastStatus = lastStatus
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case updatedAt
        case account
        case notificationsCount
        case lastStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        account = try container.decode(Account.self, forKey: .account)
        // docsは文字列としている。数で返すサーバーも読めるようにする。
        if let text = try? container.decode(String.self, forKey: .notificationsCount) {
            guard let count = Int(text) else {
                throw DecodingError.dataCorruptedError(forKey: .notificationsCount, in: container, debugDescription: "件数として読めません")
            }
            notificationsCount = ServerCount.clamped(count)
        } else {
            notificationsCount = try container.decodeCount(forKey: .notificationsCount)
        }
        // 投稿が読めなくても、その人のまとまりは並べる。抜粋が出ないだけで、受け入れや無視はできるため。
        lastStatus = try? container.decodeIfPresent(Status.self, forKey: .lastStatus)
    }
}

/// 保留中の通知の一覧の1ページ。
public struct NotificationRequestPage: Sendable, Equatable {
    /// サーバーが返す順。
    public let requests: [NotificationRequest]
    /// 続きのページを読むときの`max_id`。`Link`ヘッダーに`next`がなければnilで、これより後ろはない。
    public let nextMaxID: String?

    public init(requests: [NotificationRequest], nextMaxID: String?) {
        self.requests = requests
        self.nextMaxID = nextMaxID
    }
}

/// 保留中の通知への答え。
public enum NotificationRequestDecision: Sendable, Equatable {
    /// 保留していた通知を通知の一覧に戻し、以後その人の通知を受け入れる。
    case accept
    /// 保留中の通知から外し、数えないようにする。
    case dismiss
}
