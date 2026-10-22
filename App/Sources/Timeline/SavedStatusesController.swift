import Foundation
import os
import SciaCore
import UIKit

/// ブックマークやお気に入りの一覧の読み込みを、TimelineViewControllerの表示へつなぐ。決まりはdocs/tabs.mdの「ブックマークとお気に入り」にある。
///
/// ストリームがないため購読せず、タブで開くたびと、開いたままアプリに戻ったときに、最新のページを読んで先頭に足す。
@MainActor
final class SavedStatusesController {
    /// 1回に読む件数。APIの上限が40件。
    private static let pageSize = 40

    let viewController: TimelineViewController
    let kind: SavedStatusesKind
    private let store: SavedStatusesStore
    /// APIが401を返したときに呼ぶ。トークンが無効かを確かめ、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "timeline")
    private var tasks: [Task<Void, Never>] = []
    private var isStopped = false
    private var hasStarted = false
    /// タブで開いて見せている。見せ始めたら最新のページを読み、見せなくなったら外した行を消す。
    private var isShown = false

    init(kind: SavedStatusesKind, client: MastodonClient, onUnauthorized: @escaping () -> Void) {
        let pageSize = Self.pageSize
        store = SavedStatusesStore(kind: kind) { maxID in
            switch kind {
            case .bookmarks: try await client.bookmarks(maxID: maxID, limit: pageSize)
            case .favourites: try await client.favourites(maxID: maxID, limit: pageSize)
            }
        }
        self.kind = kind
        self.onUnauthorized = onUnauthorized
        viewController = TimelineViewController(texts: Self.texts(for: kind))
        // 公式のWebクライアントと同じく、ホームの文脈のフィルターを当て、「隠す」に一致した投稿も隠さずに警告で畳む。自分で残した投稿だから。
        viewController.filterWarnings = FilterWarnings(filtering: StatusFiltering(context: .home, myAccountID: client.credential.accountID, hidesMatches: false))
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder(origin: .automatic) }
        viewController.onRetry = { [weak self] in self?.retry() }
        // 開くまで読まない。開いたことのない一覧のために、起動のたびに通信しないため。
        viewController.onAppearing = { [weak self] in self?.startIfNeeded() }
    }

    private static func texts(for kind: SavedStatusesKind) -> TimelineViewController.Texts {
        switch kind {
        case .bookmarks: .bookmarks
        case .favourites: .favourites
        }
    }

    private var name: String { kind.rawValue }

    func startIfNeeded() {
        guard !hasStarted else { return }
        start()
    }

    /// - Parameter origin: 電波の回復などでやり直すときは`.automatic`。レート制限で止められている間は送らない。
    private func start(origin: RequestOrigin = .user) {
        guard !isStopped else { return }
        hasStarted = true
        viewController.setContentState(.loading)
        run(origin) { controller in
            controller.logger.info("\(controller.name, privacy: .public) loadInitial start")
            do {
                guard try await controller.store.loadInitial(), !controller.isStopped else { return }
                controller.viewController.setEntries(controller.store.entries)
                controller.viewController.setContentState(.loaded)
                controller.viewController.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.logger.info("\(controller.name, privacy: .public) loadInitial done count=\(controller.store.entries.count, privacy: .public)")
            } catch {
                controller.handle(error, during: "loadInitial") { controller.viewController.setContentState(.failed($0)) }
            }
        }
    }

    #if DEBUG
    /// 始めている一覧だけ読み込み直す。障害を起こすデバッグURLで、開いたことのない一覧まで読み始めないようにする。
    func reloadIfStarted() {
        guard hasStarted else { return }
        start()
    }
    #endif

    /// タブで見せ始めたか、見せなくなったかを伝える。
    /// 見せ始めたら、ほかの端末やwebで付けた分を拾うため、最新のページを読む。
    /// 見せなくなったら、外したまま残した行のうち、外すのをサーバーが受け付けたものを消す。見ていないときに消すので、動かさない。
    func setShown(_ shown: Bool) {
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
    func enterForeground() {
        guard !isStopped else { return }
        retryFailedLoads()
        if isShown {
            refreshNewest()
        }
    }

    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。失敗したままの読み込みをすぐやり直す。
    func recover() {
        guard !isStopped else { return }
        retryFailedLoads()
    }

    private func retryFailedLoads() {
        if case .failed = viewController.contentState {
            start(origin: .automatic)
        } else if case .failed = viewController.footerState {
            loadOlder(origin: .automatic)
        }
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときに呼ぶ。
    func stop() {
        isStopped = true
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func run(_ origin: RequestOrigin = .user, _ operation: @escaping @MainActor (SavedStatusesController) async -> Void) {
        tasks.removeAll { $0.isCancelled }
        // 作ったTaskは、作ったときのtask-localの値を引き継ぐ。
        let task = RequestOrigin.$current.withValue(origin) {
            Task { [weak self] in
                guard let self else { return }
                await operation(self)
            }
        }
        tasks.append(task)
    }

    private func retry() {
        if store.isLoaded {
            loadOlder()
        } else {
            start()
        }
    }

    private func loadOlder(origin: RequestOrigin = .user) {
        guard !isStopped, !store.isLoading, store.isLoaded, !store.reachedEnd else { return }
        viewController.setFooterState(.loading)
        run(origin) { controller in
            do {
                let added = try await controller.store.loadOlder()
                guard !controller.isStopped else { return }
                controller.viewController.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.showEntries()
                controller.logger.info("\(controller.name, privacy: .public) loadOlder done added=\(added, privacy: .public) reachedEnd=\(controller.store.reachedEnd, privacy: .public)")
            } catch {
                controller.handle(error, during: "loadOlder") { controller.viewController.setFooterState(.failed($0)) }
            }
        }
    }

    /// 最新のページを読み、手元より新しい分を先頭に足す。失敗しても、一覧はそのまま見せ、次に開いたときに読み直す。
    private func refreshNewest() {
        guard !isStopped, store.isLoaded, !store.isLoading else { return }
        run(.automatic) { controller in
            do {
                guard try await controller.store.refreshNewest(), !controller.isStopped else { return }
                controller.viewController.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.showEntries()
                controller.logger.info("\(controller.name, privacy: .public) refresh done count=\(controller.store.entries.count, privacy: .public)")
            } catch {
                controller.handle(error, during: "refresh") { _ in }
            }
        }
    }

    /// アプリの中で付け外しした操作を、サーバーが受け付けたときに呼ぶ。付けた投稿は先頭に入れる。
    /// 外した投稿は、見ている間は付け直せるよう残し、見ていなければすぐ消す。ほかのタブで外した行を、次に開いたときに残さないため。
    func statusDidSettle(_ action: StatusInteractions.Action, _ status: Status) {
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

    /// 投稿の中身を変える。印を外しても行は残し、外すのをサーバーが受け付けて一覧から離れたときに消す。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard !isStopped, store.updateStatus(id, transform) else { return }
        showEntries()
    }

    /// 削除した投稿を除く。使う人の操作の結果なので、閉じる動きで消す。
    func removeStatus(_ id: Status.ID) {
        guard !isStopped, store.removeStatus(id) else { return }
        showEntries(animatesRemoval: true)
    }

    /// ミュートかブロックした相手の投稿を除き、あとから読んでも足さない。使う人の操作の結果なので、閉じる動きで消す。
    func setAccount(_ id: String, excluded: Bool) {
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
        if animatesRemoval {
            viewController.setEntries(store.entries, animatesRemoval: true)
        } else {
            viewController.setEntries(store.entries, keeping: viewController.currentAnchor()?.id)
        }
        viewController.setFooterState(viewController.footerState)
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
