public import Foundation
import os

/// 確定した検索の語を、ログインしているアカウントごとに新しい順で覚える。決まりはdocs/search.mdの「最近の検索」にある。
/// `RecentMentions`と同じく、複数のウィンドウで開いても上書きし合わないよう、手元に持たずに毎回UserDefaultsを読み書きする。
@MainActor
public final class RecentSearches {
    private let defaults: UserDefaults
    private let key: String
    /// 覚えておく数。
    public static let capacity = 20

    /// - Parameter account: ログインしているアカウントのハンドル（`Credential.handle`）。
    public init(defaults: UserDefaults, account: String) {
        self.defaults = defaults
        key = AccountScopedDefaults.key("recentSearches", account: account)
    }

    /// 新しい順。
    public var queries: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// 前後の空白を除いて先頭に足す。同じ語があれば先頭へ動かす。
    public func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(Array(([trimmed] + queries.filter { $0 != trimmed }).prefix(Self.capacity)), forKey: key)
    }

    public func remove(_ query: String) {
        defaults.set(queries.filter { $0 != query }, forKey: key)
    }

    public func removeAll() {
        defaults.removeObject(forKey: key)
    }
}

/// 検索欄に打っている途中に出す候補。決まりはdocs/search.mdの「打っている途中」にある。
@MainActor
public final class SearchSuggestions {
    /// 打った語に応じて、候補の上に出す行。押すと確定と同じことをする。
    public enum Action: Hashable, Sendable {
        /// 語で探す。
        case search(String)
        /// URLの投稿かプロフィールを開く。
        case openURL(URL)
        /// ハンドルの人のプロフィールを開く。`acct`は先頭の`@`を除いたもの。
        case openHandle(acct: String)
        /// ハッシュタグの一覧を開く。`name`は`#`を除いた名前。
        case openHashtag(name: String)
    }

    /// 出す中身。語が空なら、最近の検索だけを持つ。
    public struct Content: Equatable, Sendable {
        public var actions: [Action] = []
        public var accounts: [Account] = []
        public var hashtags: [Hashtag] = []
        public var recents: [String] = []

        public init(actions: [Action] = [], accounts: [Account] = [], hashtags: [Hashtag] = [], recents: [String] = []) {
            self.actions = actions
            self.accounts = accounts
            self.hashtags = hashtags
            self.recents = recents
        }

        /// 一覧に並べる行。打った語に応じた行、ユーザー、ハッシュタグ、最近の検索の順にし、ユーザーとハッシュタグと最近の検索には見出しを付ける。
        /// ユーザーとハッシュタグは、確定した結果と同じ行で描くため、結果と同じ見出しと行を使う。
        public var entries: [TimelineEntry] {
            var entries = actions.map { TimelineEntry.search(.action($0)) }
            if !accounts.isEmpty {
                entries += [.search(.heading(.accounts))] + accounts.map(TimelineEntry.account)
            }
            if !hashtags.isEmpty {
                entries += [.search(.heading(.hashtags))] + hashtags.map { .search(.hashtag($0)) }
            }
            if !recents.isEmpty {
                entries += [.search(.recentsHeading)] + recents.map { .search(.recent($0)) }
            }
            return entries
        }
    }

    /// 中身が変わったときに呼ぶ。
    public var onChange: ((Content) -> Void)?
    public private(set) var content = Content()
    private let client: MastodonClient
    private let recents: RecentSearches
    private let settings: ComposeCompletion.Settings
    private let clock: any Clock<Duration>
    private let tasks: TaskScope
    private let logger = SciaLog.logger(category: "search")
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    public var runningTaskCount: Int { tasks.runningCount }

    /// - Parameter settings: 投稿欄の補完と同じ、問い合わせるまでの間合い、出す数、サーバーで探す文字数。
    public init(client: MastodonClient, recents: RecentSearches, settings: ComposeCompletion.Settings, clock: any Clock<Duration> = SystemTime.clock, tasks: TaskScope) {
        self.client = client
        self.recents = recents
        self.settings = settings
        self.clock = clock
        self.tasks = tasks
    }

    /// 検索欄の語が変わったときに呼ぶ。行はすぐ出し、ユーザーとハッシュタグは間をおいて探す。前の問い合わせは取り消す。
    public func update(_ text: String) {
        guard let input = SearchInput(text) else {
            tasks.cancel(key: Self.lookupKey)
            set(Content(recents: recents.queries))
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = Content(actions: Self.actions(for: input, text: trimmed))
        // 前の語の候補は、新しい語の候補が届くまで残す。打つたびに一覧が空になってちらつかないため。
        next.accounts = content.accounts
        next.hashtags = content.hashtags
        let lookup = Self.lookup(for: input)
        guard let lookup, lookup.query.count >= settings.minimumSearchQueryLength else {
            tasks.cancel(key: Self.lookupKey)
            next.accounts = []
            next.hashtags = []
            set(next)
            return
        }
        set(next)
        let client = client, settings = settings, clock = clock
        tasks.run(key: Self.lookupKey, .replacing, .display) { [weak self] in
            do {
                try await clock.sleep(for: settings.debounce)
                async let accounts = client.searchAccountsForCompletion(lookup.query, limit: settings.limit)
                async let hashtags = lookup.includesHashtags ? client.searchHashtagsForCompletion(lookup.query, limit: settings.limit) : []
                let (foundAccounts, foundHashtags) = try await (accounts, hashtags)
                guard let self, !Task.isCancelled else { return }
                var content = self.content
                content.accounts = foundAccounts
                content.hashtags = foundHashtags
                set(content)
            } catch {
                guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
                // 打っている途中の問い合わせなので、送り直さない。次に打った文字で問い合わせ直す。
                self?.logger.error("suggest failed: \(SciaLog.describe(error), privacy: .public)")
            }
        }
    }

    /// 語を確定したときに呼ぶ。最近の検索に残し、候補の問い合わせをやめる。
    public func submit(_ text: String) {
        tasks.cancel(key: Self.lookupKey)
        recents.record(text)
    }

    /// 最近の検索から1つ消す。
    public func removeRecent(_ query: String) {
        recents.remove(query)
        guard content.actions.isEmpty else { return }
        set(Content(recents: recents.queries))
    }

    /// 最近の検索をすべて消す。
    public func removeAllRecents() {
        recents.removeAll()
        guard content.actions.isEmpty else { return }
        set(Content())
    }

    /// 問い合わせを打ち切り、以後の結果を捨てる。
    public func stop() {
        tasks.close()
    }

    private static let lookupKey = "suggest"

    private func set(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        onChange?(content)
    }

    private static func actions(for input: SearchInput, text: String) -> [Action] {
        let opening: Action? = switch input {
        case .url(let url): .openURL(url)
        case .handle(let acct): .openHandle(acct: acct)
        case .hashtag(let name): .openHashtag(name: name)
        case .text: nil
        }
        return [opening, .search(text)].compactMap(\.self)
    }

    /// サーバーで候補を探す語。URLでは探さない。ハンドルではユーザーだけを、`#`で始まる語ではハッシュタグを`#`を除いた名前で探す。
    private static func lookup(for input: SearchInput) -> (query: String, includesHashtags: Bool)? {
        switch input {
        case .url: nil
        case .handle(let acct): (acct, false)
        case .hashtag(let name): (name, true)
        case .text(let text): (text, true)
        }
    }
}
