import Foundation

/// 作るか変える途中のフィルター。決まりはdocs/filters.mdの「作る、変える、消す」にある。
public struct FilterDraft: Sendable, Equatable {
    public struct Keyword: Identifiable, Sendable, Equatable {
        /// 編集の画面で行を見分ける番号。
        public let id: Int
        /// サーバーにあるキーワードのID。足したキーワードではnil。
        public let serverID: String?
        public var keyword: String
        public var wholeWord: Bool

        var isBlank: Bool { keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 変える前のフィルター。作るときはnil。
    public let original: ServerFilter?
    public var title: String
    public var contexts: Set<FilterResult.Context>
    public var action: FilterResult.Action
    public var expiry: ServerFilter.ExpiryChange
    public var keywords: [Keyword]
    private var nextKeywordID: Int

    /// 選べる対象。この順に並べ、この順に送る。
    public static let contextChoices: [FilterResult.Context] = [.home, .notifications, .public, .thread, .account]

    /// 新しく作るフィルター。どこでも警告にし、キーワードを1つ書けるようにしておく。
    public init() {
        original = nil
        title = ""
        contexts = Set(Self.contextChoices)
        action = .warn
        expiry = .never
        keywords = [Keyword(id: 0, serverID: nil, keyword: "", wholeWord: true)]
        nextKeywordID = 1
    }

    /// `filter`を変える。期限は今のままにしておく。
    public init(editing filter: ServerFilter) {
        original = filter
        title = filter.title
        contexts = Set(filter.context)
        action = filter.filterAction
        expiry = .keep
        keywords = filter.keywords.enumerated().map { Keyword(id: $0.offset, serverID: $0.element.id, keyword: $0.element.keyword, wholeWord: $0.element.wholeWord) }
        nextKeywordID = filter.keywords.count
    }

    public mutating func addKeyword() {
        keywords.append(Keyword(id: nextKeywordID, serverID: nil, keyword: "", wholeWord: true))
        nextKeywordID += 1
    }

    /// 送る名前。前後の空白は除く。
    public var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 送る対象。選べる対象の順に並べ、このアプリが知らない対象はその後ろに残す。
    public var orderedContexts: [FilterResult.Context] {
        Self.contextChoices.filter(contexts.contains) + contexts.subtracting(Self.contextChoices).sorted { $0.rawValue < $1.rawValue }
    }

    /// 名前と対象は、サーバーが必ず求める。
    public var canSave: Bool { !trimmedTitle.isEmpty && !contexts.isEmpty }

    /// 開いたときから変えたか。空のままのキーワードは数えない。
    public var hasChanges: Bool {
        let initial = original.map(Self.init(editing:)) ?? Self()
        return trimmedTitle != initial.trimmedTitle || contexts != initial.contexts || action != initial.action || expiry != initial.expiry
            || !keywordChanges.isEmpty || (original == nil && !newKeywords.isEmpty)
    }

    /// 作るときに送るキーワード。空のものは送らない。
    public var newKeywords: [ServerFilter.KeywordDraft] {
        keywords.filter { $0.serverID == nil && !$0.isBlank }.map { ServerFilter.KeywordDraft(keyword: $0.keyword, wholeWord: $0.wholeWord) }
    }

    /// 変えるときに送るキーワード。変えたもの、足したもの、消したものだけを並べる。
    /// サーバーにあるキーワードを空にしたら、消したものとして扱う。サーバーは空のキーワードを断るため。
    public var keywordChanges: [ServerFilter.KeywordChange] {
        guard let original else { return [] }
        let kept = Dictionary(keywords.compactMap { keyword in keyword.serverID.map { ($0, keyword) } }) { first, _ in first }
        let existing = original.keywords.compactMap { before -> ServerFilter.KeywordChange? in
            guard let now = kept[before.id], !now.isBlank else {
                return ServerFilter.KeywordChange(id: before.id, keyword: before.keyword, wholeWord: before.wholeWord, removes: true)
            }
            guard now.keyword != before.keyword || now.wholeWord != before.wholeWord else { return nil }
            return ServerFilter.KeywordChange(id: before.id, keyword: now.keyword, wholeWord: now.wholeWord)
        }
        return existing + newKeywords.map { ServerFilter.KeywordChange(id: nil, keyword: $0.keyword, wholeWord: $0.wholeWord) }
    }
}
