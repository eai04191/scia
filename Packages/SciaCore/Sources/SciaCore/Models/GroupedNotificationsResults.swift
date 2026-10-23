import Foundation

/// `GET /api/v2/notifications`の応答。まとまりは、アカウントと投稿をIDで指すため、組み立ててから`MastodonNotification`にする。
/// https://docs.joinmastodon.org/methods/grouped_notifications/#GroupedNotificationsResults
struct GroupedNotificationsResults: Decodable {
    let page: NotificationPage

    private enum CodingKeys: String, CodingKey {
        case accounts, statuses, notificationGroups
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accounts = Dictionary(try container.decodeLossyArray(Account.self, forKey: .accounts).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let statuses = Dictionary(try container.decodeLossyArray(Status.self, forKey: .statuses).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 読めなかった投稿も、ブラウザで開けるようURLだけは引けるようにする。
        let statusURLs = Dictionary(try container.decodeLossyArray(StatusIdentity.self, forKey: .statuses).map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        let groups = try container.decodeIfPresent([GroupElement].self, forKey: .notificationGroups) ?? []
        var notifications: [MastodonNotification] = []
        var unreadable: [UnreadableItem] = []
        for element in groups {
            switch element {
            case .readable(let group):
                if let notification = group.notification(accounts: accounts, statuses: statuses) {
                    notifications.append(notification)
                } else {
                    // 指しているアカウントや投稿が読めなかった。続きを読む位置に使えるよう、読めなかった行として残す。
                    DecodingLog.dropped(MastodonNotification.self, at: decoder.codingPath + [CodingKeys.notificationGroups], MissingReference(groupKey: group.groupKey))
                    unreadable.append(UnreadableItem(id: group.pageMaxID, url: group.statusID.flatMap { statusURLs[$0] } ?? nil, pageMinID: group.pageMinID))
                }
            case .unreadable(let item):
                unreadable.append(item)
            case .unidentifiable:
                break
            }
        }
        page = NotificationPage(notifications: notifications, unreadable: unreadable)
    }

    /// 投稿から、読めなかったときにブラウザで開くのに要るものだけを読む。
    private struct StatusIdentity: Decodable {
        let id: String
        let url: URL?

        private enum CodingKeys: String, CodingKey {
            case id, url
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            url = container.decodeDisplayURL(forKey: .url)
        }
    }

    /// まとまりが指すアカウントや投稿が、応答の中で読めなかった。
    private struct MissingReference: Error {
        let groupKey: String
    }

    /// まとまり1つ。読めなくても投げず、最も新しい通知のIDが読めれば読めなかった行にする。
    /// 読めなかった行にも、まとまりの最も古い通知のIDを残す。続きをそこから読まないと、同じまとまりの古い側を読み直して、読めない行が重なるため。
    private enum GroupElement: Decodable {
        case readable(Group)
        case unreadable(UnreadableItem)
        case unidentifiable

        init(from decoder: any Decoder) {
            do {
                self = .readable(try Group(from: decoder))
            } catch {
                DecodingLog.dropped(Group.self, at: decoder.codingPath, error)
                guard let id = try? Group.decodeID(from: decoder) else {
                    self = .unidentifiable
                    return
                }
                self = .unreadable(UnreadableItem(id: id, url: nil, pageMinID: try? Group.decodePageMinID(from: decoder)))
            }
        }
    }

    /// https://docs.joinmastodon.org/methods/grouped_notifications/#NotificationGroup
    private struct Group: Decodable {
        let groupKey: String
        let notificationsCount: Int
        let type: MastodonNotification.Kind
        /// 読んだ範囲の中で最も新しい通知のID。
        let pageMaxID: String
        let pageMinID: String
        let latestPageNotificationAt: Date
        let sampleAccountIDs: [String]
        let statusID: String?

        private enum CodingKeys: String, CodingKey {
            case groupKey, notificationsCount, type, mostRecentNotificationId, pageMinId, pageMaxId, latestPageNotificationAt, sampleAccountIds, statusId
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groupKey = try container.decode(String.self, forKey: .groupKey)
            notificationsCount = try container.decode(Int.self, forKey: .notificationsCount)
            type = try container.decode(MastodonNotification.Kind.self, forKey: .type)
            pageMaxID = try Self.decodeID(in: container)
            pageMinID = try container.decodeIfPresent(String.self, forKey: .pageMinId) ?? pageMaxID
            latestPageNotificationAt = try container.decode(Date.self, forKey: .latestPageNotificationAt)
            sampleAccountIDs = try container.decode([String].self, forKey: .sampleAccountIds)
            statusID = try container.decodeIfPresent(String.self, forKey: .statusId)
        }

        static func decodePageMinID(from decoder: any Decoder) throws -> String? {
            try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .pageMinId)
        }

        static func decodeID(from decoder: any Decoder) throws -> String {
            try decodeID(in: decoder.container(keyedBy: CodingKeys.self))
        }

        /// `page_max_id`は文字列で返るが、`most_recent_notification_id`はMastodonのサーバーが数値のまま返すため、どちらの形でも読む。
        private static func decodeID(in container: KeyedDecodingContainer<CodingKeys>) throws -> String {
            if let id = try container.decodeIfPresent(String.self, forKey: .pageMaxId) {
                return id
            }
            if let id = try? container.decode(String.self, forKey: .mostRecentNotificationId) {
                return id
            }
            return String(try container.decode(Int64.self, forKey: .mostRecentNotificationId))
        }

        /// 指しているアカウントと投稿を引いて組み立てる。最も新しい人か、指している投稿が読めなければnil。
        func notification(accounts: [String: Account], statuses: [String: Status]) -> MastodonNotification? {
            let samples = sampleAccountIDs.compactMap { accounts[$0] }
            guard let first = sampleAccountIDs.first, let account = accounts[first] else { return nil }
            let status = statusID.flatMap { statuses[$0] }
            if statusID != nil, status == nil { return nil }
            return MastodonNotification(
                id: pageMaxID,
                type: type,
                createdAt: latestPageNotificationAt,
                account: account,
                status: status,
                groupKey: groupKey,
                notificationsCount: max(notificationsCount, samples.count),
                sampleAccounts: Array(samples.prefix(MastodonNotification.maxSampleAccounts)),
                pageMinID: pageMinID
            )
        }
    }
}
