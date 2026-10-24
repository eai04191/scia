public import Foundation

/// 自分に関わる出来事の通知。FoundationのNotificationと名前がぶつかるため、Mastodonを付ける。
///
/// 通知の一覧では、同じ投稿へのお気に入りやブーストのように、サーバーがまとめた通知を1行に出す。
/// まとまりも、その中で最も新しい通知として持ち、まとまりの人数と、並べるアカウントを添える。まとめない通知は、1人のまとまりになる。
/// https://docs.joinmastodon.org/entities/Notification/
/// https://docs.joinmastodon.org/methods/grouped_notifications/#NotificationGroup
public struct MastodonNotification: Codable, Hashable, Sendable, Identifiable {
    /// 通知のID。まとまりなら、読んだ範囲の中で最も新しい通知のID。並びと既読の位置に使う。
    public let id: String
    public let type: Kind
    /// まとまりなら、`id`の通知の日時。
    public let createdAt: Date
    /// 通知のもとになる操作をしたアカウント。まとまりなら、最も新しい通知の人。
    public let account: Account
    /// お気に入り、ブースト、メンションなどの対象の投稿。フォローなどでは無い。
    public let status: Status?
    /// まとまりを表すキー。まとめない通知は`ungrouped-<通知のID>`にする。削除と、届いた通知を同じまとまりへ足すのに使う。
    public let groupKey: String
    /// まとまりに入っている通知の数。まとめない通知は1。
    public let notificationsCount: Int
    /// まとまりに通知を送った人のうち、新しい人から最大`maxSampleAccounts`人。先頭は`account`。
    public let sampleAccounts: [Account]
    /// 読んだ範囲の中で、まとまりの最も古い通知のID。続きを読む位置に使う。まとめない通知は`id`。
    public let pageMinID: String

    /// まとまりに並べるアカウントの数の上限。Mastodonのwebとサーバーに合わせる。
    public static let maxSampleAccounts = 8

    public init(
        id: String,
        type: Kind,
        createdAt: Date,
        account: Account,
        status: Status? = nil,
        groupKey: String? = nil,
        notificationsCount: Int = 1,
        sampleAccounts: [Account]? = nil,
        pageMinID: String? = nil
    ) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.account = account
        self.status = status
        self.groupKey = Self.groupKey(groupKey, of: type, id: id)
        self.notificationsCount = notificationsCount
        self.sampleAccounts = sampleAccounts ?? [account]
        self.pageMinID = pageMinID ?? id
    }

    /// まとめる種類なら届いたキーを使い、ほかは`ungrouped-<通知のID>`にする。
    /// まとめる種類を絞る`grouped_types[]`はRESTにしか効かず、ストリーミングでは、まとめない種類にもまとめるためのキーが付くため。
    private static func groupKey(_ received: String?, of type: Kind, id: String) -> String {
        guard type.isGrouped, let received else { return "ungrouped-\(id)" }
        return received
    }

    /// 2人以上の通知をまとめた行か。
    public var isGroup: Bool { notificationsCount > 1 }

    private enum CodingKeys: String, CodingKey {
        case id, type, createdAt, account, status, groupKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            type: try container.decode(Kind.self, forKey: .type),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            account: try container.decode(Account.self, forKey: .account),
            status: try container.decodeIfPresent(Status.self, forKey: .status),
            groupKey: try container.decodeIfPresent(String.self, forKey: .groupKey)
        )
    }

    /// 1件の通知の形で書く。まとまりの人数とアカウントは書かない。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(account, forKey: .account)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(groupKey, forKey: .groupKey)
    }

    /// 通知の種類。サーバーは版を重ねるごとに種類を増やすため、知らない種類も読めるようにする。
    public enum Kind: Hashable, Sendable, Codable {
        case mention
        /// 通知を有効にしたアカウントが投稿した。
        case status
        case reblog
        case follow
        case followRequest
        case favourite
        /// 投票したか作成した投票が終わった。
        case poll
        /// ブーストした投稿が編集された。
        case update
        case quote
        /// 引用した投稿が編集された。
        case quotedUpdate
        case other(String)

        /// まとめて1行に出す種類。Mastodonのwebと同じく、お気に入り、ブースト、フォローに限る。
        public static let grouped: [Kind] = [.favourite, .reblog, .follow]

        public var isGrouped: Bool { Self.grouped.contains(self) }

        public init(rawValue: String) {
            self = switch rawValue {
            case "mention": .mention
            case "status": .status
            case "reblog": .reblog
            case "follow": .follow
            case "follow_request": .followRequest
            case "favourite": .favourite
            case "poll": .poll
            case "update": .update
            case "quote": .quote
            case "quoted_update": .quotedUpdate
            default: .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .mention: "mention"
            case .status: "status"
            case .reblog: "reblog"
            case .follow: "follow"
            case .followRequest: "follow_request"
            case .favourite: "favourite"
            case .poll: "poll"
            case .update: "update"
            case .quote: "quote"
            case .quotedUpdate: "quoted_update"
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

extension MastodonNotification {
    /// 届いた1件の通知を、同じまとまりに足す。人数を1つ増やし、その人をアカウントの先頭に足して、`notification`をまとまりの最も新しい通知にする。
    /// すでに並べている人の通知（お気に入りを外して付け直したときなど）は足さず、nilを返す。
    public func adding(_ notification: MastodonNotification) -> MastodonNotification? {
        guard !sampleAccounts.contains(where: { $0.id == notification.account.id }) else { return nil }
        return MastodonNotification(
            id: notification.id,
            type: type,
            createdAt: notification.createdAt,
            account: notification.account,
            status: notification.status ?? status,
            groupKey: groupKey,
            notificationsCount: notificationsCount + 1,
            sampleAccounts: Array(([notification.account] + sampleAccounts).prefix(Self.maxSampleAccounts)),
            pageMinID: pageMinID
        )
    }

    /// まとまりの値を変えずに、対象の投稿だけを差し替える。
    func replacing(status: Status?) -> MastodonNotification {
        MastodonNotification(
            id: id, type: type, createdAt: createdAt, account: account, status: status, groupKey: groupKey,
            notificationsCount: notificationsCount, sampleAccounts: sampleAccounts, pageMinID: pageMinID
        )
    }

    /// 続きを読む位置を、`id`まで古い側へ広げる。
    func extendingPage(to id: String) -> MastodonNotification {
        guard StatusID.isNewer(pageMinID, than: id) else { return self }
        return MastodonNotification(
            id: self.id, type: type, createdAt: createdAt, account: account, status: status, groupKey: groupKey,
            notificationsCount: notificationsCount, sampleAccounts: sampleAccounts, pageMinID: id
        )
    }

    /// `accountIDs`の人を、並べるアカウントから外す。外した人の数だけ人数を減らす。並べる人が残らなければnil。
    /// まとまりの人数には並べていない人も入っているため、並べている人を外しても、ほかの人が残ることがある。
    func removingAccounts(_ accountIDs: Set<String>) -> MastodonNotification? {
        let remaining = sampleAccounts.filter { !accountIDs.contains($0.id) }
        guard remaining.count != sampleAccounts.count else { return self }
        guard let first = remaining.first else { return nil }
        return MastodonNotification(
            id: id, type: type, createdAt: createdAt, account: first, status: status, groupKey: groupKey,
            notificationsCount: max(notificationsCount - (sampleAccounts.count - remaining.count), remaining.count),
            sampleAccounts: remaining, pageMinID: pageMinID
        )
    }
}
