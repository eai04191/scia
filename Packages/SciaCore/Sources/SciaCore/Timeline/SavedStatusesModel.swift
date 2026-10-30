import Foundation
import os

/// ブックマークやお気に入りの一覧の読み込みを受け持ち、結果を一覧の画面（`TimelineDisplay`）へ命令として伝える。決まりはdocs/tabs.mdの「ブックマークとお気に入り」にある。
///
/// ストリームがないため購読せず、タブで開くたびと、開いたままアプリに戻ったときに、最新のページを読んで先頭に足す。
@MainActor
public final class SavedStatusesModel {
    /// 1回に読む件数。APIの上限が40件。
    private static let pageSize = 40

    public let kind: SavedStatusesKind
    /// 結果を伝える一覧の画面。
    public weak var display: (any TimelineDisplay)?
    /// この一覧で当てるサーバーのフィルター。公式のWebクライアントと同じく、ホームの文脈のフィルターを当て、「隠す」に一致した投稿も隠さずに警告で折りたたむ。自分で残した投稿だから。
    public let filtering: StatusFiltering
    private let store: SavedStatusesStore
    /// APIが401を返したときに呼ぶ。トークンが無効かを確かめ、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "timeline")
    /// この一覧が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときにも閉じる。
    private let tasks: TaskScope
    private var isStopped: Bool { tasks.isClosed }
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    public var runningTaskCount: Int { tasks.runningCount }
    /// 一覧全体の状態。失敗したままなら、電波の回復や引っぱった読み直しでやり直す。
    public private(set) var contentState = TimelineContentState.loaded
    /// 末尾の読み込みの状態。失敗したままなら、電波の回復でやり直す。
    public private(set) var footerState = TimelineFooterState.idle
    private var hasStarted = false
    /// タブで開いて見せている。見せ始めたら最新のページを読み、見せなくなったら外した行を消す。
    private var isShown = false

    public init(kind: SavedStatusesKind, client: MastodonClient, tasks: TaskScope, onUnauthorized: @escaping () -> Void) {
        self.tasks = tasks
        let pageSize = Self.pageSize
        store = SavedStatusesStore(kind: kind) { maxID in
            switch kind {
            case .bookmarks: try await client.bookmarks(maxID: maxID, limit: pageSize)
            case .favourites: try await client.favourites(maxID: maxID, limit: pageSize)
            }
        }
        self.kind = kind
        self.onUnauthorized = onUnauthorized
        filtering = StatusFiltering(context: .home, myAccountID: client.credential.accountID, hidesMatches: false)
    }

    private var name: String { kind.rawValue }

    /// まだ始めていなければ始める。開くまで読まない。開いたことのない一覧のために、起動のたびに通信しないため。
    public func startIfNeeded() {
        guard !hasStarted else { return }
        start()
    }

    /// - Parameter purpose: 電波の回復などでやり直すときは`.display`。レート制限で止められている間は送らない。
    @discardableResult
    private func start(purpose: RequestPurpose = .action) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        hasStarted = true
        setContentState(.loading)
        return run(purpose) { model in
            model.logger.info("\(model.name, privacy: .public) loadInitial start")
            do {
                guard try await model.store.loadInitial(), !model.isStopped else { return }
                model.display?.show(model.store.entries)
                model.setContentState(.loaded)
                model.setFooterState(model.store.reachedEnd ? .reachedEnd : .idle)
                model.logger.info("\(model.name, privacy: .public) loadInitial done count=\(model.store.entries.count, privacy: .public)")
            } catch {
                model.handle(error, during: "loadInitial") { model.setContentState(.failed($0)) }
            }
        }
    }

    #if DEBUG
    /// 始めている一覧だけ読み込み直す。障害を起こすデバッグURLで、開いたことのない一覧まで読み始めないようにする。
    public func reloadIfStarted() {
        guard hasStarted else { return }
        start()
    }
    #endif

    /// タブで見せ始めたか、見せなくなったかを伝える。
    /// 見せ始めたら、ほかの端末やwebで付けた分を拾うため、最新のページを読む。
    /// 見せなくなったら、外したまま残した行のうち、外すのをサーバーが受け付けたものを消す。見ていないときに消すので、動かさない。
    public func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown {
            refreshNewest()
        } else if !isStopped, store.pruneUnsaved() {
            logger.info("\(self.name, privacy: .public) pruned unsaved")
            showEntries()
        }
    }

    /// バックグラウンドから戻ったときに呼ぶ。開いたままなら、離れていた間に付けた分を拾う。
    public func enterForeground() {
        guard !isStopped else { return }
        retryFailedLoads()
        if isShown {
            refreshNewest()
        }
    }

    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。失敗したままの読み込みをすぐやり直す。
    public func recover() {
        guard !isStopped else { return }
        retryFailedLoads()
    }

    private func retryFailedLoads() {
        if case .failed = contentState {
            start(purpose: .display)
        } else if case .failed = footerState {
            loadOlder(purpose: .display)
        }
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。セッションを閉じたときは、呼ばなくても持ち主が閉じて止まる。
    public func stop() {
        tasks.close()
    }

    @discardableResult
    private func run(_ purpose: RequestPurpose = .action, _ operation: @escaping @MainActor (SavedStatusesModel) async -> Void) -> Task<Void, Never>? {
        // 作ったTaskは、作ったときのtask-localの値を引き継ぐ。
        RequestPurpose.$current.withValue(purpose) {
            tasks.run { [weak self] in
                guard let self else { return }
                await operation(self)
            }
        }
    }

    private func setContentState(_ state: TimelineContentState) {
        contentState = state
        display?.setContentState(state)
    }

    private func setFooterState(_ state: TimelineFooterState) {
        footerState = state
        display?.setFooterState(state)
    }

    /// 一覧を引っぱって離したときに、最新のページを読んで、一番上の投稿より後に付けた分を上に足す。
    /// 最初の読み込みに失敗したままなら、それをやり直す。
    public func refresh() async {
        guard !isStopped, hasStarted else { return }
        logger.info("\(self.name, privacy: .public) refresh")
        if case .failed = contentState {
            await start()?.value
            return
        }
        // タブを開いたときなどの読み込みの最中なら、ストアは重ねて読まないため、終わってから読む。
        await tasks.waitForRunning()
        await refreshNewest(purpose: .action)?.value
    }

    /// 失敗の表示の再試行が押されたときに呼ぶ。
    public func retry() {
        if store.isLoaded {
            loadOlder()
        } else {
            start()
        }
    }

    /// 末尾が近づいたときに呼ぶ。古い投稿を自動で読む。
    public func approachEnd() {
        loadOlder(purpose: .display)
    }

    private func loadOlder(purpose: RequestPurpose = .action) {
        guard !isStopped, !store.isLoading, store.isLoaded, !store.reachedEnd else { return }
        setFooterState(.loading)
        run(purpose) { model in
            do {
                let added = try await model.store.loadOlder()
                guard !model.isStopped else { return }
                model.setFooterState(model.store.reachedEnd ? .reachedEnd : .idle)
                model.showEntries()
                model.logger.info("\(model.name, privacy: .public) loadOlder done added=\(added, privacy: .public) reachedEnd=\(model.store.reachedEnd, privacy: .public)")
            } catch {
                model.handle(error, during: "loadOlder") { model.setFooterState(.failed($0)) }
            }
        }
    }

    /// 最新のページを読み、手元より新しい分を先頭に足す。失敗しても、一覧はそのまま見せ、次に開いたときに読み直す。
    @discardableResult
    private func refreshNewest(purpose: RequestPurpose = .display) -> Task<Void, Never>? {
        guard !isStopped, store.isLoaded, !store.isLoading else { return nil }
        return run(purpose) { model in
            do {
                guard try await model.store.refreshNewest(), !model.isStopped else { return }
                model.setFooterState(model.store.reachedEnd ? .reachedEnd : .idle)
                model.showEntries()
                model.logger.info("\(model.name, privacy: .public) refresh done count=\(model.store.entries.count, privacy: .public)")
            } catch {
                model.handle(error, during: "refresh") { _ in }
            }
        }
    }

    /// 押したギャップを1ページ分読む。押した位置の側に続く行を基準にして、その位置を保つ。
    /// 間は上からしか読めないため、押した位置で変えるのは、位置を保つ行だけにする。
    public func selectGap(_ id: String, from direction: TimelineStore.GapDirection) {
        guard !isStopped, !store.loadingGapIDs.contains(id), let index = store.entries.firstIndex(where: { $0.id == .gap(id) }) else { return }
        let neighborIndex = direction == .fromOlder ? store.entries.index(after: index) : store.entries.index(before: index)
        let anchorID = store.entries.indices.contains(neighborIndex) ? store.entries[neighborIndex].id : nil
        display?.setGapStates(loading: store.loadingGapIDs.union([id]), failures: store.gapFailures.filter { $0.key != id })
        run { model in
            do {
                let changed = try await model.store.loadGap(id)
                guard !model.isStopped else { return }
                model.showGapStates()
                guard changed != nil else { return }
                model.display?.show(model.store.entries, keeping: anchorID)
                model.logger.info("\(model.name, privacy: .public) loadGap done count=\(model.store.entries.count, privacy: .public)")
            } catch {
                model.showGapStates()
                model.handle(error, during: "loadGap") { _ in }
            }
        }
    }

    private func showGapStates() {
        display?.setGapStates(loading: store.loadingGapIDs, failures: store.gapFailures)
    }

    /// アプリの中で付け外しした操作を、サーバーが受け付けたときに呼ぶ。付けた投稿は先頭に入れる。
    /// 外した投稿は、見ている間は付け直せるよう残し、見ていなければすぐ消す。ほかのタブで外した行を、次に開いたときに残さないため。
    public func statusDidSettle(_ action: StatusInteractions.Action, _ status: Status) {
        guard !isStopped, action == kind.action else { return }
        if kind.isSaved(status.displayed) {
            guard store.insertSaved(status) else { return }
            logger.info("\(self.name, privacy: .public) inserted saved status=\(status.displayed.id, privacy: .public)")
            showEntries()
        } else {
            store.markUnsaved(status)
            guard !isShown, store.pruneUnsaved() else { return }
            logger.info("\(self.name, privacy: .public) pruned unsaved while hidden")
            showEntries()
        }
    }

    /// 投稿の中身を変える。ブックマークやお気に入りを外しても行は残し、外すのをサーバーが受け付けて一覧から離れたときに消す。
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard !isStopped, store.updateStatus(id, transform) else { return }
        showEntries()
    }

    /// 削除した投稿を除く。使う人の操作の結果なので、閉じる動きで消す。
    public func removeStatus(_ id: Status.ID) {
        guard !isStopped, store.removeStatus(id) else { return }
        showEntries(animatesRemoval: true)
    }

    /// ミュートかブロックした相手の投稿を除き、あとから読んでも足さない。使う人の操作の結果なので、閉じる動きで消す。
    public func setAccount(_ id: String, excluded: Bool) {
        guard !isStopped else { return }
        guard excluded else {
            store.includeAccount(id)
            return
        }
        guard store.excludeAccount(id) else { return }
        showEntries(animatesRemoval: true)
    }

    /// 並びを描き直す。フッターの文は、行がないときとあるときで変わるため、一緒に描き直す。
    ///
    /// 先頭に足したときは、最上部にいても新着のように追従せず、表示領域の上端にかかっている行の位置を保つ。
    /// 付けた投稿や、ほかの端末で付けた投稿は、読んでいる行を動かしてまで見せるものではないため。
    /// - Parameter animatesRemoval: 使う人の操作で行を消した。消える行を閉じる動きで消す。
    private func showEntries(animatesRemoval: Bool = false) {
        showGapStates()
        if animatesRemoval {
            display?.show(store.entries, animatesRemoval: true)
        } else {
            display?.show(store.entries, keeping: display?.currentAnchorID())
        }
        setFooterState(footerState)
    }

    private func handle(_ error: any Error, during operation: String, show: (ErrorPresentation) -> Void) {
        // 止めた後に届いた結果や、止めたことによる取り消しは、もう画面に関係しない。
        guard !isStopped, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        logger.error("\(self.name, privacy: .public) \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized()
        }
        show(ErrorPresentation(error))
    }
}
