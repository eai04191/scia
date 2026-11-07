import Foundation
import os

/// 確定した語で探し、結果を並べる画面（`TimelineDisplay`）へ伝える。決まりはdocs/search.mdにある。
///
/// 3つの種類を並行に読み、届いたものから見せる。ストリームも既読位置もない。
@MainActor
public final class SearchModel {
    /// 何を並べるか。
    public enum Scope: Hashable, Sendable {
        /// 3つの種類を、ユーザー、ハッシュタグ、投稿の順に見出しを付けて並べる。
        case all
        /// 1つの種類だけを、見出しなしで並べ、スクロールで続きを読む。「すべて見る」で開く画面。
        case only(SearchCategory)
    }

    /// URLやハンドルが1つに決まったもの。結果のリストの上に開く。
    public enum Found: Equatable, Sendable {
        case status(Status)
        case account(Account)
    }

    /// 3つの種類を並べるときに、ユーザーとハッシュタグを出す件数。これより多ければ「すべて見る」を出す。
    public static let previewCount = 5
    /// 投稿を1回に読む件数。
    private static let statusPageSize = 20
    /// 1つの種類だけの画面で、ユーザーとハッシュタグを1回に読む件数。APIの上限が40件。
    private static let listPageSize = 40

    public let input: SearchInput
    public let scope: Scope
    /// 結果を伝える画面。
    public weak var display: (any TimelineDisplay)?
    /// URLやハンドルが1つに決まったときに呼ぶ。最初の読み込みでだけ呼び、引っぱって読み直したときは呼ばない。
    public var onFound: ((Found) -> Void)?
    private let credential: Credential
    private let client: MastodonClient
    private let pagers: [SearchCategory: SearchPager]
    private var states: [SearchCategory: SectionState] = [:]
    /// 確定してから、最初の結果がそろうまでの間か。この間に届いた結果は、確定した操作の結果として動きで見せる。確定から間をおかずに届くため、動かさずに入れると、確定の動きの途中で行が跳ねて見えるため。
    private var isSettlingSubmission = false
    /// 打っている途中の候補から引き継いだ行。その種類の結果が届くまで、見出しの下に出す。確定した直後にリストが空にならず、同じ行がその場に残るようにするため。
    private var carried: [SearchCategory: [TimelineEntry]] = [:]
    /// 最後に始めた読み込み。古い読み込みの結果を捨てるのに使う。
    private var generation = 0
    private let logger = SciaLog.logger(category: "search")
    /// この検索が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときと、画面を閉じたときに閉じる。
    private let tasks: TaskScope
    private var isStopped: Bool { tasks.isClosed }
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    public var runningTaskCount: Int { tasks.runningCount }

    private enum SectionState: Equatable {
        case loading
        case loaded
        case failed(ErrorPresentation)
    }

    /// - Parameters:
    ///   - carriedAccounts: 打っている途中の候補のユーザー。3つの種類を並べるときに、ユーザーの結果が届くまで出す。
    ///   - carriedHashtags: 打っている途中の候補のハッシュタグ。3つの種類を並べるときに、ハッシュタグの結果が届くまで出す。
    public init(input: SearchInput, scope: Scope = .all, carriedAccounts: [Account] = [], carriedHashtags: [Hashtag] = [], client: MastodonClient, tasks: TaskScope) {
        self.input = input
        self.scope = scope
        self.client = client
        credential = client.credential
        self.tasks = tasks
        let query = input.query
        var pagers: [SearchCategory: SearchPager] = [:]
        for category in Self.categories(of: scope) {
            let pageSize = switch (scope, category) {
            case (_, .statuses): Self.statusPageSize
            // 「すべて見る」を出すかを決めるため、出す件数より1件多く読む。
            case (.all, _): Self.previewCount + 1
            case (.only, _): Self.listPageSize
            }
            // 知らない相手のサーバーのユーザーも探す。ハッシュタグと投稿では意味がないため、送らない。
            let resolve = category == .accounts
            pagers[category] = SearchPager(category: category, pageSize: pageSize) { offset, limit in
                try await client.search(query, category: category, resolve: resolve, limit: limit, offset: offset)
            }
        }
        self.pagers = pagers
        if scope == .all {
            carried[.accounts] = carriedAccounts.prefix(Self.previewCount).map(TimelineEntry.account)
            carried[.hashtags] = carriedHashtags.prefix(Self.previewCount).map { .search(.hashtag($0)) }
        }
    }

    private static func categories(of scope: Scope) -> [SearchCategory] {
        switch scope {
        case .all: SearchCategory.allCases
        case .only(let category): [category]
        }
    }

    private var categories: [SearchCategory] { Self.categories(of: scope) }

    /// 探し始める。リストに残っていた候補の行を最初の結果に置き換えるまでを、確定した操作の結果として動きで見せる。
    public func start() {
        guard !isStopped else { return }
        isSettlingSubmission = true
        display?.setContentState(.loading)
        load(isRefresh: false, purpose: .action)
    }

    /// 結果を伝える画面を付け替え、今の結果を並べ直す。検索欄で打ち直してから閉じ、候補から結果に戻すときに使う。
    public func attach(_ display: any TimelineDisplay) {
        self.display = display
        guard !isStopped else { return }
        render(arrived: true)
    }

    /// 結果のリストを引っぱって離したときに、同じ語でもう一度探す。読めるまでは、前の結果を残す。
    public func refresh() async {
        guard !isStopped else { return }
        logger.info("refresh")
        // 読み込んでいる途中なら、終わってから読み直す。Pagerは重ねて読まないため、途中で世代だけを進めると、走っている読み込みの結果も捨てて、読み込み中のまま止まる。
        await tasks.waitForRunning()
        for task in load(isRefresh: true, purpose: .action) {
            await task.value
        }
    }

    /// 読めなかった種類を読み直す。失敗の表示の再試行と、失敗の行を押したときに呼ぶ。
    /// - Parameter category: 読み直す種類。nilなら、最初の読み込みに失敗した種類と、続きの読み込みに失敗した種類をすべて読み直す。
    public func retry(_ category: SearchCategory? = nil) {
        guard !isStopped else { return }
        // URLは1回の問い合わせで読み込ませるため、失敗したら同じ問い合わせをやり直す。種類ごとの検索では、投稿のURLを読み込まないため。
        if isResolvingURL, categories.contains(where: { if case .failed = states[$0] { true } else { false } }) {
            load(isRefresh: false, purpose: .action)
            return
        }
        let failed = categories.filter { if case .failed = states[$0] { $0 == category || category == nil } else { false } }
        guard !failed.isEmpty else {
            loadNext(purpose: .action)
            return
        }
        for category in failed {
            states[category] = .loading
            loadInitial(category, generation: generation, isRefresh: false, purpose: .action)
        }
        render(arrived: true)
    }

    /// 末尾が近づいたときに呼ぶ（どこまで近づいたらかは`TimelineLoadTrigger.isApproachingEnd(displaying:count:)`）。続きを読む。
    public func approachEnd() {
        loadNext(purpose: .display)
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。
    public func stop() {
        tasks.close()
    }

    /// URLなら、まとめて1回で読み込ませる。ほかは種類ごとに並行に読む。始めた処理を返す。
    @discardableResult
    private func load(isRefresh: Bool, purpose: RequestPurpose) -> [Task<Void, Never>] {
        generation += 1
        let generation = generation
        if !isRefresh {
            for category in categories {
                states[category] = .loading
            }
            render(arrived: true)
        }
        if isResolvingURL {
            let task = run(purpose) { model in
                do {
                    let results = try await model.client.search(model.input.query, category: nil, resolve: true, limit: Self.previewCount)
                    guard generation == model.generation, !model.isStopped else { return }
                    for category in model.categories {
                        model.pagers[category]?.adopt(results)
                        model.states[category] = .loaded
                        model.nextFailures[category] = nil
                    }
                    model.render(arrived: true)
                    model.logger.info("resolve url done accounts=\(results.accounts.count, privacy: .public) statuses=\(results.statuses.count, privacy: .public)")
                    if !isRefresh {
                        model.reportFound(in: results)
                    }
                } catch {
                    guard generation == model.generation else { return }
                    model.handle(error, during: "resolve url") { presentation in
                        for category in model.categories where !isRefresh || model.states[category] != .loaded {
                            model.states[category] = .failed(presentation)
                        }
                    }
                    model.render()
                }
            }
            return task.map { [$0] } ?? []
        }
        return categories.compactMap { loadInitial($0, generation: generation, isRefresh: isRefresh, purpose: purpose) }
    }

    @discardableResult
    private func loadInitial(_ category: SearchCategory, generation: Int, isRefresh: Bool, purpose: RequestPurpose) -> Task<Void, Never>? {
        guard let pager = pagers[category] else { return nil }
        return run(purpose) { model in
            do {
                guard try await pager.loadInitial(), generation == model.generation, !model.isStopped else { return }
                model.states[category] = .loaded
                // 先頭から読み直したので、前の続きの読み込みの失敗はもう関係しない。
                model.nextFailures[category] = nil
                model.render(arrived: true)
                model.logger.info("loadInitial done category=\(category.rawValue, privacy: .public) count=\(pager.count, privacy: .public)")
                if !isRefresh, category == .accounts, case .handle = model.input,
                   let account = pager.accounts.first(where: { model.input.names($0, on: model.credential) }) {
                    model.onFound?(.account(account))
                }
            } catch {
                guard generation == model.generation else { return }
                // 読み直しに失敗しても、前の結果があれば残す。
                model.handle(error, during: "loadInitial \(category.rawValue)") { presentation in
                    if !isRefresh || model.states[category] != .loaded {
                        model.states[category] = .failed(presentation)
                    }
                }
                model.render(arrived: true)
            }
        }
    }

    /// URLを1回の問い合わせで読み込ませる。
    private var isResolvingURL: Bool {
        if case .url = input, scope == .all { true } else { false }
    }

    /// 続きを読む種類。3つを並べるときは投稿だけ、1つだけの画面ではその種類。URLを読み込ませたときは、続きを読まない。
    private var pagedCategory: SearchCategory? {
        switch scope {
        case .all: isResolvingURL ? nil : .statuses
        case .only(let category): category
        }
    }

    private func loadNext(purpose: RequestPurpose) {
        guard !isStopped, let category = pagedCategory, let pager = pagers[category], states[category] == .loaded,
              !pager.isLoading, !pager.reachedEnd, pager.count > 0 else { return }
        nextFailures[category] = nil
        display?.setFooterState(.loading)
        let generation = generation
        run(purpose) { model in
            do {
                guard let added = try await pager.loadNext(), generation == model.generation, !model.isStopped else { return }
                model.render()
                model.logger.info("loadNext done category=\(category.rawValue, privacy: .public) added=\(added, privacy: .public) reachedEnd=\(pager.reachedEnd, privacy: .public)")
            } catch {
                guard generation == model.generation else { return }
                model.handle(error, during: "loadNext \(category.rawValue)") { model.nextFailures[category] = $0 }
                model.render()
            }
        }
    }

    /// 続きの読み込みに失敗した種類と、その失敗。フッターに出す。
    private var nextFailures: [SearchCategory: ErrorPresentation] = [:]

    /// URLを読み込ませた結果が、投稿かユーザーの1つに決まれば知らせる。
    private func reportFound(in results: SearchResults) {
        guard results.statuses.count + results.accounts.count == 1, results.unreadableStatuses.isEmpty else { return }
        if let status = results.statuses.first {
            onFound?(.status(status))
        } else if let account = results.accounts.first {
            onFound?(.account(account))
        }
    }

    /// 投稿の中身を変える。
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard !isStopped, pagers[.statuses]?.updateStatus(id, transform) == true else { return }
        render()
    }

    /// 削除した投稿を除く。使う人の操作の結果なので、閉じる動きで消す。
    public func removeStatus(_ id: Status.ID) {
        guard !isStopped, pagers[.statuses]?.removeStatuses(where: { $0.id == .status(id) || $0.id == .unreadable(id) }) == true else { return }
        render(animatesRemoval: true)
    }

    /// ミュートかブロックした相手の投稿を除く。使う人の操作の結果なので、閉じる動きで消す。読み直せば、サーバーが除いた結果に戻る。
    public func excludeAccount(_ id: String) {
        guard !isStopped, pagers[.statuses]?.removeStatuses(where: { entry in
            guard case .status(let status) = entry else { return false }
            return status.account.id == id || status.reblog?.account.id == id
        }) == true else { return }
        render(animatesRemoval: true)
    }

    /// 今の状態から並びと、リスト全体とフッターの状態を作って伝える。
    /// - Parameter arrived: 種類の結果が届いた。届いた種類はほかの種類の上に入ることがあり、行を基準に保つと、最上部にいても先に届いた種類の位置に留まって、上に入った結果が画面の外に出るため、スクロール位置をそのまま保つ。
    private func render(arrived: Bool = false, animatesRemoval: Bool = false) {
        var entries: [TimelineEntry] = []
        for category in categories {
            guard let pager = pagers[category] else { continue }
            switch states[category] {
            case .failed(let presentation):
                // 投稿の失敗はフッターに出す。ほかの種類は、見出しの下に失敗の行を出す。
                // URLは1回の問い合わせなので、種類ごとに出さず、リスト全体の失敗にする。
                if scope == .all, category != .statuses, !isResolvingURL {
                    entries += [.search(.heading(category)), .search(.failed(category, presentation))]
                }
            case .loaded:
                entries += rows(of: pager)
            case .loading, nil:
                if let rows = carried[category], !rows.isEmpty {
                    entries += [.search(.heading(category))] + rows
                }
                continue
            }
            // 結果が届くか失敗したら、引き継いだ行はもう出さない。
            carried[category] = nil
        }
        if animatesRemoval {
            display?.show(entries, animatesRemoval: true)
        } else if isSettlingSubmission {
            display?.transition(to: entries)
            if !categories.contains(where: { states[$0] == .loading || states[$0] == nil }) {
                isSettlingSubmission = false
            }
        } else if arrived {
            display?.setEntries(entries, keeping: nil, placingAtTop: nil, keepsOffset: true, animatesRemoval: false, keepingRowContentsOf: nil)
        } else {
            display?.show(entries, keeping: display?.currentAnchorID())
        }
        display?.setContentState(contentState(isEmpty: entries.isEmpty))
        // 行がないときは、見つからなかったことをリストの全面に出す。フッターの終わりの文にも同じ文が出て重なるため、終わりを出さない。
        display?.setFooterState(entries.isEmpty && footerState == .reachedEnd ? .idle : footerState)
    }

    private func rows(of pager: SearchPager) -> [TimelineEntry] {
        guard pager.count > 0 else { return [] }
        switch scope {
        case .only:
            return items(of: pager, limit: nil)
        case .all:
            let limit = pager.category == .statuses ? nil : Self.previewCount
            let more: [TimelineEntry] = limit.map { pager.count > $0 } == true ? [.search(.showAll(pager.category))] : []
            return [.search(.heading(pager.category))] + items(of: pager, limit: limit) + more
        }
    }

    private func items(of pager: SearchPager, limit: Int?) -> [TimelineEntry] {
        let limit = limit ?? .max
        return switch pager.category {
        case .accounts: pager.accounts.prefix(limit).map(TimelineEntry.account)
        case .hashtags: pager.hashtags.prefix(limit).map { .search(.hashtag($0)) }
        case .statuses: Array(pager.statuses.prefix(limit))
        }
    }

    /// 行がなければ、読んでいる途中なら読み込み中、読めなかった種類があれば失敗、ほかは見つからなかったことを出す。
    private func contentState(isEmpty: Bool) -> TimelineContentState {
        guard isEmpty else { return .loaded }
        if categories.contains(where: { states[$0] == .loading || states[$0] == nil }) {
            return .loading
        }
        for category in categories {
            if case .failed(let presentation) = states[category] {
                return .failed(presentation)
            }
        }
        return .loaded
    }

    private var footerState: TimelineFooterState {
        // 続きを読む種類がないとき（URLを読み込ませたとき）は、読み終えるまで終わりを出さない。行がなければ、終わりの文に見つからなかったことを出すため。
        guard let category = pagedCategory, let pager = pagers[category] else {
            return categories.contains { states[$0] == .loading || states[$0] == nil } ? .idle : .reachedEnd
        }
        if let failure = nextFailures[category] {
            return .failed(failure)
        }
        switch states[category] {
        case .loading, nil:
            // 3つを並べるときは、ほかの種類が先に届いても、投稿を読んでいることを末尾に出す。
            return .loading
        case .failed(let presentation):
            return scope == .all ? .failed(presentation) : .reachedEnd
        case .loaded:
            return pager.isLoading ? .loading : pager.reachedEnd ? .reachedEnd : .idle
        }
    }

    @discardableResult
    private func run(_ purpose: RequestPurpose, _ operation: @escaping @MainActor (SearchModel) async -> Void) -> Task<Void, Never>? {
        tasks.run(purpose) { [weak self] in
            guard let self else { return }
            await operation(self)
        }
    }

    private func handle(_ error: any Error, during operation: String, show: (ErrorPresentation) -> Void) {
        // 止めた後に届いた結果や、止めたことによる取り消しは、もう画面に関係しない。
        guard !isStopped, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        logger.error("\(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        show(ErrorPresentation(error))
    }
}

extension SearchModel: SessionStatusList {}
