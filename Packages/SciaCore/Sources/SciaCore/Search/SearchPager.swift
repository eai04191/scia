/// 検索の結果に並ぶ、投稿と人のほかの行。
public enum SearchRow: Hashable, Sendable {
    /// 種類の見出し。
    case heading(SearchCategory)
    case hashtag(Hashtag)
    /// その種類だけの結果を開く。
    case showAll(SearchCategory)
    /// その種類を読めなかった。押すと読み直す。
    case failed(SearchCategory, ErrorPresentation)
    /// 打っている途中に、語の形に応じて候補の上に出す行。押すと確定と同じことをする。
    case action(SearchSuggestions.Action)
    /// 最近の検索の見出し。「すべて消す」を添える。
    case recentsHeading
    /// 最近の検索の1つ。押すとその語で確定する。
    case recent(String)

    public var id: String {
        switch self {
        case .heading(let category): "heading-\(category.rawValue)"
        case .hashtag(let hashtag): "hashtag-\(Hashtag.normalizedName(hashtag.name))"
        case .showAll(let category): "showAll-\(category.rawValue)"
        case .failed(let category, _): "failed-\(category.rawValue)"
        case .action(let action): "action-\(action)"
        case .recentsHeading: "recentsHeading"
        case .recent(let query): "recent-\(query)"
        }
    }

    /// 違和感レポートの状態ダンプに書く、行の名前。打った語、最近の検索の語、ハッシュタグの名前は、docs/logging.mdで公開扱いにしない情報なので書かない。
    /// IDが決まった語だけでできている行（見出し、「すべて見る」、失敗の行）はそのまま書き、ほかは種類だけにする。語を含む行を足したときに、ここに足し忘れても漏れないようにするため。
    public static func dumpLabel(ofID id: String) -> String {
        let kind = String(id.prefix { $0 != "-" })
        return ["heading", "showAll", "failed", "recentsHeading"].contains(kind) ? id : kind
    }

    /// 見出しの行か。見出しは押せず、区切り線の引き方も違う。
    public var isHeading: Bool {
        switch self {
        case .heading, .recentsHeading: true
        case .hashtag, .showAll, .failed, .action, .recent: false
        }
    }
}

/// 検索の結果の1つの種類を、先頭から続きへ読み進めて持つ。決まりはdocs/search.mdの「確定したとき」にある。
///
/// MastodonのAPIは`offset`で続きを読む。ほかの検索のサービスを足すときは、この部品を差し替える。
@MainActor
public final class SearchPager {
    /// `offset`から`limit`件を読む。
    public typealias Fetch = @Sendable (_ offset: Int, _ limit: Int) async throws -> SearchResults

    public let category: SearchCategory
    private let pageSize: Int
    private let fetch: Fetch
    /// 読んだ人。同じ人は1度だけ並べる。
    public private(set) var accounts: [Account] = []
    /// 読んだハッシュタグ。サーバーと同じ決まりでそろえた名前が同じものは、1度だけ並べる。
    public private(set) var hashtags: [Hashtag] = []
    /// 読んだ投稿と読めなかった投稿。サーバーが返す順（新しい順）。同じIDは1度だけ並べる。
    public private(set) var statuses: [TimelineEntry] = []
    /// これより後ろはない。
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false
    /// 次に読む位置。サーバーはミュートやブロックした人の投稿を除く前の件数で数えるため、読めた件数ではなく、頼んだ件数を足す。
    private var offset = 0

    public init(category: SearchCategory, pageSize: Int, fetch: @escaping Fetch) {
        self.category = category
        self.pageSize = pageSize
        self.fetch = fetch
    }

    public var count: Int {
        switch category {
        case .accounts: accounts.count
        case .hashtags: hashtags.count
        case .statuses: statuses.count
        }
    }

    /// 最初のページで置き換える。読み込み中なら何もせずfalseを返す。
    @discardableResult
    public func loadInitial() async throws -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        let results = try await fetch(0, pageSize)
        accounts = []
        hashtags = []
        statuses = []
        offset = 0
        apply(results)
        return true
    }

    /// 続きのページを読み、新たに足した件数を返す。読み込み中か、終わりに着いていれば何もせずnilを返す。
    public func loadNext() async throws -> Int? {
        guard !isLoading, !reachedEnd else { return nil }
        isLoading = true
        defer { isLoading = false }
        let before = count
        apply(try await fetch(offset, pageSize))
        return count - before
    }

    /// まとめて探した結果を、続きのない結果として持つ。URLを読み込ませた結果に使う。
    public func adopt(_ results: SearchResults) {
        accounts = []
        hashtags = []
        statuses = []
        apply(results)
        reachedEnd = true
    }

    /// サーバーは除いた投稿を数えずに返すため、読んだ件数が頼んだ件数より少なくても続きがあることがある。終わりにするのは、1件も返らなかったときだけにする。
    private func apply(_ results: SearchResults) {
        offset += pageSize
        reachedEnd = results.count(of: category) == 0
        switch category {
        case .accounts:
            var seen = Set(accounts.map(\.id))
            accounts += results.accounts.filter { seen.insert($0.id).inserted }
        case .hashtags:
            var seen = Set(hashtags.map { Hashtag.normalizedName($0.name) })
            hashtags += results.hashtags.filter { seen.insert(Hashtag.normalizedName($0.name)).inserted }
        case .statuses:
            // 読めなかった投稿は、読めた投稿とは別の配列で届くため、IDで新しい順に並べ直してからつなげる。
            let page = (results.statuses.map(TimelineEntry.status) + results.unreadableStatuses.map(TimelineEntry.unreadable))
                .sorted { StatusID.isNewer(Self.rawID(of: $0), than: Self.rawID(of: $1)) }
            var seen = Set(statuses.map(\.id))
            statuses += page.filter { seen.insert($0.id).inserted }
        }
    }

    private static func rawID(of entry: TimelineEntry) -> String {
        switch entry {
        case .status(let status): status.id
        case .unreadable(let item): item.id
        case .gap, .notification, .pinned, .account, .notificationRequest, .search: ""
        }
    }

    /// 投稿の中身を変える。ブーストした投稿の中の投稿も変える。変えた投稿があればtrue。
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) -> Bool {
        let updated = statuses.map { entry in
            guard case .status(let status) = entry else { return entry }
            return .status(TimelineStore.updating(id, in: status, transform))
        }
        guard updated != statuses else { return false }
        statuses = updated
        return true
    }

    /// `belongs`に当てはまる行を除く。除いた行があればtrue。
    public func removeStatuses(where belongs: (TimelineEntry) -> Bool) -> Bool {
        let before = statuses.count
        statuses.removeAll(where: belongs)
        return statuses.count != before
    }
}
