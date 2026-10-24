public import Foundation

/// ハッシュタグのミュート。Mastodonにはハッシュタグをミュートする仕組みがないため、`#名前`を単語として一致させる、隠すフィルターで代わりにする。
/// 決まりはdocs/menus.mdの「ハッシュタグのメニュー」にある。
public struct HashtagMute: Sendable, Equatable {
    /// このタグに一致するキーワードを持つ、1つのフィルター。
    public struct Match: Sendable, Equatable {
        public let filterID: String
        /// このタグに一致するキーワード。表記の違う同じタグのキーワードが1つのフィルターに並ぶこともある。
        public let keywordIDs: [String]
        /// フィルターがこのタグのキーワードしか持たないので、解除するときはフィルターごと消す。
        /// ほかのキーワードか、1件ずつ指定して隠す投稿もあれば、このタグのキーワードだけを消し、ほかは残す。使う人が作ったほかの条件を消さないため。
        public let removesFilter: Bool

        public init(filterID: String, keywordIDs: [String], removesFilter: Bool) {
            self.filterID = filterID
            self.keywordIDs = keywordIDs
            self.removesFilter = removesFilter
        }
    }

    /// このタグを隠しているフィルターすべて。1つでも残すと、解除しても隠れたままになるため、まとめて解除する。
    public let matches: [Match]

    public init(matches: [Match]) {
        self.matches = matches
    }

    /// 作るフィルターを当てる場所。ミュートなので、フィルターを当てられる場所すべてにする。
    public static let contexts: [FilterResult.Context] = [.home, .notifications, .public, .thread, .account]

    /// フィルターのキーワード。本文の`#名前`に一致させる。
    public static func keyword(for name: String) -> String {
        "#\(name)"
    }

    /// ミュートの条件と比べる値。フィルターのキーワードの一致と同じく、大文字と小文字だけをそろえる。
    static func matchingKey(for name: String) -> String {
        keyword(for: name).lowercased()
    }

    /// `filters`のうち、このタグをミュートしているもの。1つもなければnil。隠さないフィルターと、期限が切れたフィルターは数えない。
    /// Mastodonのフィルターのキーワードは、大文字と小文字だけを区別せずに文字どおり一致し、全角と半角やアクセント記号はそろえない（`CustomFilterKeyword#to_regex`）。
    /// 判定がサーバーとずれると、隠れていないのにミュート中と見なしたり、解除で別の表記の条件を消したりするため、同じ決まりで比べる。
    public static func find(_ name: String, in filters: [ServerFilter], now: Date) -> HashtagMute? {
        let key = matchingKey(for: name)
        let matches = filters.compactMap { filter -> Match? in
            guard filter.filterAction == .hide, filter.expiresAt.map({ $0 > now }) ?? true else { return nil }
            let matched = filter.keywords.filter { $0.keyword.trimmingCharacters(in: .whitespaces).lowercased() == key }
            guard !matched.isEmpty else { return nil }
            return Match(filterID: filter.id, keywordIDs: matched.map(\.id), removesFilter: matched.count == filter.keywords.count && filter.statuses.isEmpty)
        }
        return matches.isEmpty ? nil : HashtagMute(matches: matches)
    }

    /// `name`をミュートするフィルターを作る。フィルターの名前は`#名前`にする。
    /// - Parameter duration: ミュートを続ける時間。nilなら解除するまで続ける。
    public static func mute(_ name: String, duration: Duration?, client: MastodonClient) async throws {
        _ = try await client.createFilter(
            title: keyword(for: name),
            context: contexts,
            action: .hide,
            expiresIn: duration,
            keywords: [ServerFilter.KeywordDraft(keyword: keyword(for: name), wholeWord: true)]
        )
    }

    /// ミュートを解除する。ほかの条件も持つフィルターは、このタグのキーワードだけ消す。
    public func unmute(client: MastodonClient) async throws {
        for match in matches {
            if match.removesFilter {
                try await client.deleteFilter(match.filterID)
            } else {
                for keywordID in match.keywordIDs {
                    try await client.deleteFilterKeyword(keywordID)
                }
            }
        }
    }
}

extension Status {
    /// 表示する投稿（ブーストなら元の投稿）に、ミュートの条件`key`（`HashtagMute.matchingKey(for:)`）に一致するタグがあるか。
    func hasTag(matching key: String) -> Bool {
        displayed.tags.contains { HashtagMute.matchingKey(for: $0.name) == key }
    }
}
