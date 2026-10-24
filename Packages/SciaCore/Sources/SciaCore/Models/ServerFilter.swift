public import Foundation

/// 使う人がサーバーに作ったフィルター。投稿に付くフィルターの結果（`FilterResult.Filter`）と違い、キーワードも持つ。
/// https://docs.joinmastodon.org/entities/Filter/
public struct ServerFilter: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let context: [FilterResult.Context]
    public let filterAction: FilterResult.Action
    /// フィルターの期限。期限のないフィルターではnil。
    public let expiresAt: Date?
    public let keywords: [Keyword]
    /// 1件ずつ指定して隠す投稿。
    public let statuses: [FilteredStatus]

    /// https://docs.joinmastodon.org/entities/FilterStatus/
    public struct FilteredStatus: Decodable, Hashable, Sendable, Identifiable {
        public let id: String
        public let statusId: String

        public init(id: String, statusId: String) {
            self.id = id
            self.statusId = statusId
        }
    }

    /// https://docs.joinmastodon.org/entities/FilterKeyword/
    public struct Keyword: Decodable, Hashable, Sendable, Identifiable {
        public let id: String
        public let keyword: String
        /// 単語の区切りで一致させるか。
        public let wholeWord: Bool

        public init(id: String, keyword: String, wholeWord: Bool) {
            self.id = id
            self.keyword = keyword
            self.wholeWord = wholeWord
        }
    }

    /// フィルターを作るときに足すキーワード。
    public struct KeywordDraft: Sendable, Equatable {
        public let keyword: String
        public let wholeWord: Bool

        public init(keyword: String, wholeWord: Bool) {
            self.keyword = keyword
            self.wholeWord = wholeWord
        }
    }

    public init(id: String, title: String, context: [FilterResult.Context], filterAction: FilterResult.Action, expiresAt: Date? = nil, keywords: [Keyword], statuses: [FilteredStatus] = []) {
        self.id = id
        self.title = title
        self.context = context
        self.filterAction = filterAction
        self.expiresAt = expiresAt
        self.keywords = keywords
        self.statuses = statuses
    }
}
