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

    /// フィルターを変えるときの、キーワード1つの変更。
    public struct KeywordChange: Sendable, Equatable {
        /// 変えるか消すキーワードのID。足すキーワードではnil。
        public let id: String?
        public let keyword: String
        public let wholeWord: Bool
        /// `id`のキーワードを消す。
        public let removes: Bool

        public init(id: String?, keyword: String, wholeWord: Bool, removes: Bool = false) {
            self.id = id
            self.keyword = keyword
            self.wholeWord = wholeWord
            self.removes = removes
        }
    }

    /// フィルターを変えるときの、期限の変え方。
    public enum ExpiryChange: Sendable, Hashable {
        /// 今の期限のままにする。
        case keep
        /// 期限を外す。
        case never
        /// 保存したときから数えた期限にする。
        case after(Duration)
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
