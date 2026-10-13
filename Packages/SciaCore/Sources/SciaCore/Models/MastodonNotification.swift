public import Foundation

/// 自分に関わる出来事の通知。FoundationのNotificationと名前がぶつかるため、Mastodonを付ける。
/// https://docs.joinmastodon.org/entities/Notification/
public struct MastodonNotification: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let type: Kind
    public let createdAt: Date
    /// 通知のもとになる操作をしたアカウント。
    public let account: Account
    /// お気に入り、ブースト、メンションなどの対象の投稿。フォローなどでは無い。
    public let status: Status?

    public init(id: String, type: Kind, createdAt: Date, account: Account, status: Status? = nil) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.account = account
        self.status = status
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
