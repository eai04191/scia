import Foundation
public import Observation
import os

/// 補完の候補1つ。
public enum CompletionCandidate: Hashable, Sendable, Identifiable {
    case account(Account)
    case hashtag(Hashtag)
    /// プロフィールに載せているタグか、最近使ったタグ。サーバーの検索結果と同じタグなら、こちらだけを出す。
    case ownHashtag(OwnHashtag)
    /// 返信先の人か、補完で選んだことのある人。サーバーの検索結果と同じ人なら、こちらだけを出す。
    case localAccount(LocalMention, LocalMentionSource)
    case emoji(ServerEmoji)

    public var id: String {
        switch self {
        case .account(let account): "account:\(account.id)"
        case .localAccount(let mention, _): "account:\(mention.id)"
        // サーバーが同じタグとして扱う表記は、同じ候補とみなす。
        case .hashtag(let hashtag): "hashtag:\(Hashtag.normalizedName(hashtag.name))"
        case .ownHashtag(let hashtag): "hashtag:\(Hashtag.normalizedName(hashtag.name))"
        case .emoji(let emoji): "emoji:\(emoji.shortcode)"
        }
    }

    /// 選んだときに本文へ入れる文字。メンションは自分のサーバーから見たacctで、リモートのアカウントなら`@user@domain`になる。
    public var completion: String {
        switch self {
        case .account(let account): "@\(account.acct)"
        case .localAccount(let mention, _): "@\(mention.acct)"
        case .hashtag(let hashtag): "#\(hashtag.name)"
        case .ownHashtag(let hashtag): "#\(hashtag.name)"
        case .emoji(let emoji): ":\(emoji.shortcode):"
        }
    }
}

/// 手元のメンションの候補を、どこから出したか。
public enum LocalMentionSource: Hashable, Sendable {
    case reply
    case recent
}

/// カスタム絵文字の一覧から、打った語に合うものを選ぶ。
public enum EmojiCompletion {
    /// 大文字小文字を区別せず、語で始まるものを先に、語を含むものを後に並べる。それぞれ短い順、同じ長さなら名前の順。
    /// 一覧に出さない絵文字は除く。
    public static func candidates(matching query: String, in emojis: [ServerEmoji], limit: Int) -> [ServerEmoji] {
        let query = query.lowercased()
        var prefixed: [ServerEmoji] = []
        var contained: [ServerEmoji] = []
        for emoji in emojis where emoji.visibleInPicker {
            let shortcode = emoji.shortcode.lowercased()
            if shortcode.hasPrefix(query) {
                prefixed.append(emoji)
            } else if shortcode.contains(query) {
                contained.append(emoji)
            }
        }
        let order: (ServerEmoji, ServerEmoji) -> Bool = { lhs, rhs in
            lhs.shortcode.count != rhs.shortcode.count ? lhs.shortcode.count < rhs.shortcode.count : lhs.shortcode.lowercased() < rhs.shortcode.lowercased()
        }
        return Array((prefixed.sorted(by: order) + contained.sorted(by: order)).prefix(max(limit, 0)))
    }
}

/// 投稿欄の補完の状態。打った語から候補を探し、出すものを決める。
///
/// メンションとハッシュタグは、打つのが止まるまで少し待ってから問い合わせ、語が変わったら前の問い合わせを取り消す。
/// 取り消しが間に合わず届いた古い応答は捨てる。一度引いた語は覚えておき、消して打ち直したときに問い合わせ直さない。
/// カスタム絵文字は一覧をまとめて一度だけ取り、手元で絞る。
/// ハッシュタグは、プロフィールに載せているタグと最近使ったタグも一度だけ取り、打った語に合うものを検索結果より上に出す。
/// メンションは、返信先の人と補完で選んだことのある人を、同じく検索結果より上に出す。
/// サーバーの検索は自分が使ったかを見ず、名前の短い順やサーバー全体の人気で並べるため、よく使うタグや人が候補から押し出されることがある。
/// 打った文字数がサーバーで探す文字数に届くまでは、問い合わせずに、この手元の候補だけを出す。記号だけの時点から出せるようにするため。
/// 失敗しても、打つのは止めない。候補の場所で知らせ、押すと問い合わせ直す。
@MainActor
@Observable
public final class ComposeCompletion {
    /// 候補を探す口。テストでは差し替える。
    public struct Sources: Sendable {
        public var searchAccounts: @Sendable (String, Int) async throws -> [Account]
        public var searchHashtags: @Sendable (String, Int) async throws -> [Hashtag]
        public var customEmojis: @Sendable () async throws -> [ServerEmoji]
        public var featuredTags: @Sendable () async throws -> [FeaturedTag]
        public var recentTags: @Sendable () async throws -> [Hashtag]
        /// アカウントをIDでまとめて読む。返信先でメンションされた人のように、アイコンと表示名が手元にない人に使う。読めなかった人は返さない。
        public var accounts: @Sendable ([String]) async throws -> [Account]

        public init(
            searchAccounts: @escaping @Sendable (String, Int) async throws -> [Account],
            searchHashtags: @escaping @Sendable (String, Int) async throws -> [Hashtag],
            customEmojis: @escaping @Sendable () async throws -> [ServerEmoji],
            featuredTags: @escaping @Sendable () async throws -> [FeaturedTag] = { [] },
            recentTags: @escaping @Sendable () async throws -> [Hashtag] = { [] },
            accounts: @escaping @Sendable ([String]) async throws -> [Account] = { _ in [] }
        ) {
            self.searchAccounts = searchAccounts
            self.searchHashtags = searchHashtags
            self.customEmojis = customEmojis
            self.featuredTags = featuredTags
            self.recentTags = recentTags
            self.accounts = accounts
        }

        public init(client: MastodonClient) {
            self.init(
                searchAccounts: { try await client.searchAccountsForCompletion($0, limit: $1) },
                searchHashtags: { try await client.searchHashtagsForCompletion($0, limit: $1) },
                customEmojis: { try await client.customEmojis() },
                featuredTags: { try await client.featuredTags() },
                recentTags: { try await client.featuredTagSuggestions() },
                accounts: { try await client.accounts($0) }
            )
        }

        /// 補完を使わない画面とテストで使う。
        public static var unavailable: Sources {
            Sources(searchAccounts: { _, _ in [] }, searchHashtags: { _, _ in [] }, customEmojis: { [] })
        }
    }

    /// 好みで決まる値。チューニングから渡す。
    public struct Settings: Equatable, Sendable {
        /// 打つのが止まってから問い合わせるまでの時間。
        public var debounce: Duration
        /// 出す候補の数。
        public var limit: Int
        /// メンションとハッシュタグで、記号のあとに何文字打ったらサーバーで探すか。英数字以外は1文字を2文字と数える。
        /// 届くまでは手元の候補だけを出す。
        public var minimumSearchQueryLength: Int

        public init(debounce: Duration, limit: Int, minimumSearchQueryLength: Int = 1) {
            self.debounce = debounce
            self.limit = limit
            self.minimumSearchQueryLength = minimumSearchQueryLength
        }
    }

    /// 候補の場所に出すもの。
    public enum Content: Equatable, Sendable {
        case candidates([CompletionCandidate])
        /// まだ1つも候補がなく、探している。
        case loading
        /// 探したが、合うものがなかった。
        case empty
        /// 探せなかった。理由の文言を持つ。押すと問い合わせ直す。
        case failed(String)
        /// 検索は失敗したが、合う自分のタグは出せる。自分のタグの下に失敗を出す。
        case candidatesWithFailure([CompletionCandidate], String)
    }

    /// 今の語。閉じていても持ち、語が変わったかを見分けるのに使う。
    public private(set) var token: CompletionToken?
    /// Escで閉じた。語が変わるまで出さない。
    public private(set) var isDismissed = false
    public private(set) var candidates: [CompletionCandidate] = []
    public private(set) var isLoading = false
    private var failureMessage: String?
    /// ハードウェアキーボードで選んでいる候補。
    public private(set) var selectedIndex = 0
    public var settings: Settings

    /// 出すもの。出さないならnil。
    public var content: Content? {
        guard let token, !isDismissed else { return nil }
        // 手元の候補だけを出す間は、合うものがなければ何も出さない。「一致しない」と出すと、記号を打つたびに一覧が出るため。
        if !searchesServer(token), candidates.isEmpty { return nil }
        if let failureMessage {
            return candidates.isEmpty ? .failed(failureMessage) : .candidatesWithFailure(candidates, failureMessage)
        }
        if !candidates.isEmpty { return .candidates(candidates) }
        return isLoading ? .loading : .empty
    }

    /// Tab・Returnで確定する候補。候補を出していなければnil。
    public var selectedCandidate: CompletionCandidate? {
        let candidates = selectableCandidates
        guard candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex]
    }

    /// 選べる候補。出していなければ空。
    private var selectableCandidates: [CompletionCandidate] {
        switch content {
        case .candidates(let candidates), .candidatesWithFailure(let candidates, _): candidates
        case .loading, .empty, .failed, nil: []
        }
    }

    @ObservationIgnored private let sources: Sources
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var emojiTask: Task<Void, Never>?
    /// 一覧に出す絵文字。読み終えるまではnil。絵文字のパレットも、この一覧を並べる。
    public private(set) var emojis: [ServerEmoji]?
    /// 絵文字の一覧を読めなかった理由の文言。パレットに出す。読み直し始めたらnilに戻す。
    public private(set) var emojiFailureMessage: String?
    /// プロフィールに載せているタグと最近使ったタグ。読めるまではnilで、次に書き始めたときに読み直す。
    @ObservationIgnored private var featuredTags: [FeaturedTag]?
    @ObservationIgnored private var recentTags: [Hashtag]?
    @ObservationIgnored private var ownTagsTask: Task<Void, Never>?
    /// 自分のタグを読んでいる間はtrue。テストで、読み終えて候補に混ぜ直すまで待つ。
    var isLoadingOwnTags: Bool { ownTagsTask != nil }
    /// 始めた検索のうち、取り消されたものも含めて終えた数。テストで、取り消した検索が終わるまで待つ。
    @ObservationIgnored private(set) var finishedSearchCount = 0
    /// 返信先の人。書いている途中で返信先が変わることがあるので、候補を出すたびに読む。返信でなければ空。
    @ObservationIgnored public var replyParticipants: () -> [LocalMention] = { [] }
    @ObservationIgnored private let recentMentions: RecentMentions?
    /// 返信先でメンションされた人のうち、読んだアカウント。
    @ObservationIgnored private var participantAccounts: [String: Account] = [:]
    /// 読み始めた人。失敗しても読み直さない。アイコンと表示名がなくても、ハンドルで選べるため。
    @ObservationIgnored private var requestedParticipantIDs: Set<String> = []
    /// 返信先の人を読み始めた回数。テストで、読み直していないことを確かめる。
    @ObservationIgnored private(set) var replyParticipantLoadCount = 0
    @ObservationIgnored private var cache: [SearchKey: [CompletionCandidate]] = [:]
    @ObservationIgnored private let logger = SciaLog.logger(category: "compose")
    /// 覚えておく語の数。超えたら全部忘れる。
    private static let cacheLimit = 64

    private struct SearchKey: Hashable {
        let kind: CompletionKind
        let query: String
        let limit: Int

        init(_ token: CompletionToken, limit: Int) {
            kind = token.kind
            // サーバーの検索は大文字小文字を区別しない。
            query = token.query.lowercased()
            self.limit = limit
        }
    }

    /// - Parameter recentMentions: 補完で選んだアカウントを覚える場所。なければ覚えず、出さない。
    public init(sources: Sources, settings: Settings, recentMentions: RecentMentions? = nil, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await SystemTime.clock.sleep(for: $0) }) {
        self.sources = sources
        self.settings = settings
        self.recentMentions = recentMentions
        self.sleep = sleep
    }

    /// 本文が変わったら、カーソルの位置の語を渡す。語が変われば、閉じていても出し直す。
    /// 変換中の文字があるときは語がnilになり、閉じる。確定したら語を読み直して出す。
    public func textDidChange(_ new: CompletionToken?) {
        guard let new else {
            clear()
            return
        }
        let previous = token
        token = new
        if let previous, previous.kind == new.kind, previous.query == new.query {
            return
        }
        isDismissed = false
        selectedIndex = 0
        if previous?.kind != new.kind {
            candidates = []
        }
        load()
    }

    /// カーソルだけが動いたら、カーソルの位置の語を渡す。同じ語の中なら今のままにし、語の外へ出たら閉じる。
    /// 打たずにカーソルで語に入っただけでは出さない。
    ///
    /// UIKitは打った文字を入れたとき、本文が変わった知らせより先にカーソルが動いた知らせを送る。
    /// そのため語の中身は比べず、どこから始まる語かだけを見て、語が伸びたことは本文が変わった知らせで扱う。
    public func selectionDidChange(_ new: CompletionToken?) {
        guard let token else { return }
        guard let new, new.kind == token.kind, new.range.lowerBound == token.range.lowerBound else {
            clear()
            return
        }
    }

    /// Escで閉じる。語が変わるまで出さない。
    public func dismiss() {
        guard token != nil, !isDismissed else { return }
        isDismissed = true
    }

    /// 候補を選んで本文に入れたら呼ぶ。入れた後のカーソルは語の外なので閉じる。アカウントなら覚え、次から手元の候補に出す。
    public func didComplete(_ candidate: CompletionCandidate? = nil) {
        switch candidate {
        case .account(let account): recentMentions?.record(LocalMention(account: account))
        case .localAccount(let mention, _): recentMentions?.record(mention)
        case .hashtag, .ownHashtag, .emoji, nil: break
        }
        clear()
    }

    /// ハードウェアキーボードの↑↓で、選ぶ候補を移す。端では止める。
    public func moveSelection(by offset: Int) {
        let candidates = selectableCandidates
        guard !candidates.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), candidates.count - 1)
    }

    /// 失敗の表示を押したら、問い合わせ直す。
    public func retry() {
        guard token != nil else { return }
        failureMessage = nil
        load()
    }

    /// 書き始めたときに、絵文字の一覧と自分のタグを先に読んでおく。打ったときに待たずに出せるようにするため。
    /// 絵文字の一覧が読めなかったら、絵文字の語を打ったときに読み直す。
    /// 自分のタグは補助なので、読めなくても知らせず、次に書き始めたときに読み直す。
    public func prefetch() {
        if emojis == nil {
            loadEmojis()
        }
        loadParticipantAccounts()
        if featuredTags == nil || recentTags == nil {
            loadOwnTags()
        }
    }

    private func clear() {
        searchTask?.cancel()
        searchTask = nil
        token = nil
        isDismissed = false
        candidates = []
        isLoading = false
        failureMessage = nil
        selectedIndex = 0
    }

    private func load() {
        guard let token else { return }
        searchTask?.cancel()
        searchTask = nil
        failureMessage = nil
        switch token.kind {
        case .emoji:
            if let emojis {
                show(EmojiCompletion.candidates(matching: token.query, in: emojis, limit: settings.limit).map(CompletionCandidate.emoji))
            } else {
                isLoading = true
                loadEmojis()
            }
        case .mention, .hashtag:
            if token.kind == .mention {
                // 書いている途中で返信先が変わることがあるので、書き始めたときに読んでいなければここで読む。
                loadParticipantAccounts()
            }
            guard searchesServer(token) else {
                show(Array(localCandidates().prefix(settings.limit)))
                return
            }
            let key = SearchKey(token, limit: settings.limit)
            if let cached = cache[key] {
                show(merged(cached))
                return
            }
            // 合う手元の候補があれば、検索を待たずに出す。なければ前の語の候補を、届くまで出したままにする。
            // 打つたびに一覧が消えて出る点滅を避けるため。
            showWhileLoading(localCandidates())
            isLoading = true
            searchTask = Task { [weak self, sources, sleep, settings] in
                defer { self?.finishedSearchCount += 1 }
                do {
                    try await sleep(settings.debounce)
                    let candidates = try await RequestOrigin.$current.withValue(.automatic) {
                        try await Self.search(key, sources: sources)
                    }
                    guard !Task.isCancelled else { return }
                    self?.receive(candidates, for: key)
                } catch {
                    guard !Task.isCancelled, !Self.isCancellation(error) else { return }
                    self?.fail(error, for: key)
                }
            }
        }
    }

    private nonisolated static func search(_ key: SearchKey, sources: Sources) async throws -> [CompletionCandidate] {
        switch key.kind {
        case .mention:
            try await sources.searchAccounts(key.query, key.limit).prefix(key.limit).map(CompletionCandidate.account)
        case .hashtag:
            try await sources.searchHashtags(key.query, key.limit).prefix(key.limit).map(CompletionCandidate.hashtag)
        case .emoji:
            []
        }
    }

    /// 語の文字数が、サーバーで探す文字数に届いているか。絵文字は手元の一覧で絞るので、いつも届いている扱いにする。
    private func searchesServer(_ token: CompletionToken) -> Bool {
        token.kind == .emoji || CompletionTokenizer.queryLength(token.query) >= settings.minimumSearchQueryLength
    }

    /// 今の語に合う手元の候補。ハッシュタグなら自分のタグ、メンションなら返信先の人と補完で選んだことのある人。
    private func localCandidates() -> [CompletionCandidate] {
        switch token?.kind {
        case .hashtag: ownCandidates()
        case .mention: localMentionCandidates()
        case .emoji, nil: []
        }
    }

    private func ownCandidates() -> [CompletionCandidate] {
        guard let token else { return [] }
        let tags = OwnHashtag.list(featured: featuredTags ?? [], recent: recentTags ?? [])
        return OwnHashtag.matching(token.query, in: tags).map(CompletionCandidate.ownHashtag)
    }

    /// 返信先の人を先に、補完で選んだことのある人を新しい順に後に並べる。同じ人は先に出る方だけを残す。
    /// 返信先でメンションされた人は表示名とアイコンを持たないので、覚えている同じ人がいればその情報で出し、表示名でも探せるようにする。
    private func localMentionCandidates() -> [CompletionCandidate] {
        guard let token else { return [] }
        let recent = recentMentions?.mentions ?? []
        let remembered = Dictionary(recent.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let participants = replyParticipants().map { participant in
            if participant.hasProfile { return participant }
            return participantAccounts[participant.id].map(LocalMention.init(account:)) ?? remembered[participant.id] ?? participant
        }
        var seen = Set<String>()
        let all = participants.map { ($0, LocalMentionSource.reply) } + recent.map { ($0, LocalMentionSource.recent) }
        let unique = all.filter { seen.insert($0.0.id).inserted }
        let sources = Dictionary(uniqueKeysWithValues: unique.map { ($0.0.id, $0.1) })
        return LocalMention.matching(token.query, in: unique.map(\.0)).compactMap { mention in
            sources[mention.id].map { CompletionCandidate.localAccount(mention, $0) }
        }
    }

    /// 手元の候補を先に、サーバーの検索結果を後に並べ、同じタグや人は手元の方だけを残して、候補の数で切る。
    private func merged(_ searched: [CompletionCandidate]) -> [CompletionCandidate] {
        let own = localCandidates()
        let ids = Set(own.map(\.id))
        return Array((own + searched.filter { !ids.contains($0.id) }).prefix(settings.limit))
    }

    private func show(_ candidates: [CompletionCandidate]) {
        self.candidates = candidates
        isLoading = false
        selectedIndex = min(selectedIndex, max(candidates.count - 1, 0))
    }

    /// 届いた応答が今の語のものなら出す。語が変わっていれば、覚えるだけで出さない。
    private func receive(_ candidates: [CompletionCandidate], for key: SearchKey) {
        if cache.count >= Self.cacheLimit {
            cache.removeAll()
        }
        cache[key] = candidates
        guard let token, SearchKey(token, limit: settings.limit) == key else { return }
        searchTask = nil
        show(merged(candidates))
    }

    private func fail(_ error: any Error, for key: SearchKey) {
        logger.info("completion: \(key.kind.rawValue, privacy: .public) search failed: \(ErrorPresentation(error).code ?? "unknown", privacy: .public)")
        guard let token, SearchKey(token, limit: settings.limit) == key else { return }
        searchTask = nil
        // 合う手元の候補は、検索が失敗しても選べるまま残す。
        candidates = Array(localCandidates().prefix(settings.limit))
        selectedIndex = min(selectedIndex, max(candidates.count - 1, 0))
        isLoading = false
        failureMessage = Self.failureMessage(for: error)
    }

    /// 候補の場所に出す、失敗の理由。止められている間の文言は、補完では自動で読み込み直さないため、押せば読み込めることを伝える。
    public nonisolated static func failureMessage(for error: any Error) -> String {
        if let paused = error as? AutomaticRequestsPaused {
            return "短い間にリクエストが多すぎたため、サーバーに一時的に止められています。\(paused.until.formatted(date: .omitted, time: .shortened))を過ぎたら、押すと読み込み直せます。"
        }
        return ErrorPresentation(error).text
    }

    /// 絵文字のパレットを開いたときに呼ぶ。まだ読めていなければ読む。失敗していたら読み直す。
    public func loadEmojisIfNeeded() {
        guard emojis == nil else { return }
        loadEmojis()
    }

    private func loadEmojis() {
        guard emojiTask == nil else { return }
        emojiFailureMessage = nil
        emojiTask = Task { [weak self, sources] in
            do {
                let emojis = try await RequestOrigin.$current.withValue(.automatic) {
                    try await sources.customEmojis()
                }
                self?.didLoadEmojis(emojis)
            } catch {
                self?.didFailEmojis(error)
            }
        }
    }

    private func didLoadEmojis(_ loaded: [ServerEmoji]) {
        emojiTask = nil
        emojis = loaded.filter(\.visibleInPicker)
        logger.info("completion: loaded \(loaded.count, privacy: .public) custom emojis")
        guard token?.kind == .emoji, failureMessage == nil else { return }
        load()
    }

    private func didFailEmojis(_ error: any Error) {
        emojiTask = nil
        logger.info("completion: custom emojis failed: \(ErrorPresentation(error).code ?? "unknown", privacy: .public)")
        emojiFailureMessage = Self.failureMessage(for: error)
        guard token?.kind == .emoji else { return }
        candidates = []
        isLoading = false
        failureMessage = Self.failureMessage(for: error)
    }

    /// 2つを並べて読み、読めた方だけを持つ。読めなかった方はログに残し、次に書き始めたときに読み直す。
    private func loadOwnTags() {
        guard ownTagsTask == nil else { return }
        let loadsFeatured = featuredTags == nil
        let loadsRecent = recentTags == nil
        ownTagsTask = Task { [weak self, sources] in
            let (featuredResult, recentResult) = await RequestOrigin.$current.withValue(.automatic) {
                async let featured = Self.result(loadsFeatured ? sources.featuredTags : nil)
                async let recent = Self.result(loadsRecent ? sources.recentTags : nil)
                return await (featured, recent)
            }
            self?.didLoadOwnTags(featured: featuredResult, recent: recentResult)
        }
    }

    private nonisolated static func result<T: Sendable>(_ load: (@Sendable () async throws -> [T])?) async -> Result<[T], any Error>? {
        guard let load else { return nil }
        do {
            return .success(try await load())
        } catch {
            return .failure(error)
        }
    }

    private func didLoadOwnTags(featured: Result<[FeaturedTag], any Error>?, recent: Result<[Hashtag], any Error>?) {
        ownTagsTask = nil
        switch featured {
        case .success(let tags): featuredTags = tags
        case .failure(let error): logger.info("completion: featured tags failed: \(ErrorPresentation(error).code ?? "unknown", privacy: .public)")
        case nil: break
        }
        switch recent {
        case .success(let tags): recentTags = tags
        case .failure(let error): logger.info("completion: recent tags failed: \(ErrorPresentation(error).code ?? "unknown", privacy: .public)")
        case nil: break
        }
        logger.info("completion: own tags featured=\(self.featuredTags?.count ?? -1, privacy: .public) recent=\(self.recentTags?.count ?? -1, privacy: .public)")
        // 打っているタグの候補に、読めた自分のタグを混ぜ直す。
        guard let token, token.kind == .hashtag else { return }
        if failureMessage != nil {
            showWhileLoading(ownCandidates())
        } else if let cached = cache[SearchKey(token, limit: settings.limit)] {
            show(merged(cached))
        } else {
            showWhileLoading(ownCandidates())
        }
    }

    /// 返信先でメンションされた人のアカウントを、まだ読んでいなければまとめて読む。届いたら、出しているメンションの候補を描き直す。
    private func loadParticipantAccounts() {
        let ids = replyParticipants().filter { !$0.hasProfile && !requestedParticipantIDs.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        requestedParticipantIDs.formUnion(ids)
        replyParticipantLoadCount += 1
        Task { [weak self, sources] in
            do {
                let accounts = try await RequestOrigin.$current.withValue(.automatic) {
                    try await sources.accounts(ids)
                }
                self?.didLoadParticipants(accounts)
            } catch {
                self?.logger.info("completion: reply participants failed: \(ErrorPresentation(error).code ?? "unknown", privacy: .public)")
            }
        }
    }

    private func didLoadParticipants(_ accounts: [Account]) {
        guard !accounts.isEmpty else { return }
        for account in accounts {
            participantAccounts[account.id] = account
        }
        guard let token, token.kind == .mention, !isDismissed else { return }
        if !searchesServer(token) {
            show(Array(localCandidates().prefix(settings.limit)))
        } else if failureMessage == nil, let cached = cache[SearchKey(token, limit: settings.limit)] {
            show(merged(cached))
        } else {
            showWhileLoading(localCandidates())
        }
    }

    /// 検索を待つ間に、合う自分のタグを出す。なければ前の語の候補を出したままにする。
    /// 前の語の候補で下の方を選んでいても、選んでいる位置を新しい候補の中に収める。
    private func showWhileLoading(_ own: [CompletionCandidate]) {
        guard !own.isEmpty else { return }
        candidates = Array(own.prefix(settings.limit))
        selectedIndex = min(selectedIndex, candidates.count - 1)
    }

    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
