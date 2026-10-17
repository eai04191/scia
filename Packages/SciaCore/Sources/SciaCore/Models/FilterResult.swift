public import Foundation

/// 投稿に当たった、自分のフィルター。
/// https://docs.joinmastodon.org/entities/FilterResult/
public struct FilterResult: Codable, Hashable, Sendable {
    public let filter: Filter
    /// 当たったキーワード。
    public let keywordMatches: [String]?
    /// 当たった投稿のID。
    public let statusMatches: [String]?

    public init(filter: Filter, keywordMatches: [String]? = nil, statusMatches: [String]? = nil) {
        self.filter = filter
        self.keywordMatches = keywordMatches
        self.statusMatches = statusMatches
    }

    /// 当たったフィルター。投稿に付くときは、キーワードと投稿の一覧を含まない。
    /// https://docs.joinmastodon.org/entities/Filter/
    public struct Filter: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let title: String
        /// フィルターを使う場所。
        public let context: [Context]
        /// 当たった投稿をどう扱うか。
        public let filterAction: Action
        /// フィルターの期限。期限のないフィルターではnil。
        public let expiresAt: Date?

        public init(id: String, title: String, context: [Context], filterAction: Action, expiresAt: Date? = nil) {
            self.id = id
            self.title = title
            self.context = context
            self.filterAction = filterAction
            self.expiresAt = expiresAt
        }
    }

    /// https://docs.joinmastodon.org/entities/Filter/#context
    public enum Context: Hashable, Sendable, Codable {
        /// ホームとリスト。
        case home
        case notifications
        /// 公開タイムライン。
        case `public`
        /// 投稿を開いたときのスレッド。
        case thread
        /// プロフィール。
        case account
        /// このアプリが知らない場所。
        case other(String)

        public init(rawValue: String) {
            self = switch rawValue {
            case "home": .home
            case "notifications": .notifications
            case "public": .public
            case "thread": .thread
            case "account": .account
            default: .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .home: "home"
            case .notifications: "notifications"
            case .public: "public"
            case .thread: "thread"
            case .account: "account"
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

    /// https://docs.joinmastodon.org/entities/Filter/#filter_action
    public enum Action: Hashable, Sendable, Codable {
        /// フィルターの名前を示して隠し、開けるようにする。
        case warn
        /// 表示しない。
        case hide
        /// 添付ファイルを、フィルターの名前を示してぼかす。Mastodon 4.4から。
        case blur
        /// このアプリが知らない扱い。ドキュメントは`warn`と同じに扱うよう求めている。
        case other(String)

        public init(rawValue: String) {
            self = switch rawValue {
            case "warn": .warn
            case "hide": .hide
            case "blur": .blur
            default: .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .warn: "warn"
            case .hide: "hide"
            case .blur: "blur"
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
