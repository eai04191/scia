import Foundation
import os
import SciaCore

/// 人の一覧（お気に入りした人、ブーストした人、フォロワー、フォロー）の読み込みを、TimelineViewControllerの表示へつなぐ。
/// 画面はプロフィールやスレッドと同じくpushで開く。決まりはdocs/account-list.mdにある。
@MainActor
final class AccountListController {
    /// 1回に読む件数。APIの上限は80件。
    private static let pageSize = 40

    private weak var viewController: TimelineViewController?
    private let store: AccountListStore
    /// APIが401を返したときに呼ぶ。トークンが無効かを確かめ、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "accountList")
    /// この画面が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときと、画面を閉じてこのコントローラーが捨てられたときに閉じる。
    private let tasks: TaskScope

    static func make(kind: AccountListKind, client: MastodonClient, tasks: TaskScope, onUnauthorized: @escaping () -> Void) -> (AccountListController, TimelineViewController) {
        // 画面を作る時点ではコントローラーがまだないため、作ったあとに入れる。
        weak var owner: AccountListController?
        let viewController = TimelineViewController(texts: .accountList(kind)) { await owner?.refresh() }
        let controller = AccountListController(kind: kind, client: client, viewController: viewController, tasks: tasks, onUnauthorized: onUnauthorized)
        viewController.lifetimeOwner = controller
        owner = controller
        return (controller, viewController)
    }

    private init(kind: AccountListKind, client: MastodonClient, viewController: TimelineViewController, tasks: TaskScope, onUnauthorized: @escaping () -> Void) {
        self.tasks = tasks
        let pageSize = Self.pageSize
        store = AccountListStore(kind: kind) { maxID in
            try await client.accounts(in: kind, maxID: maxID, limit: pageSize)
        }
        self.viewController = viewController
        self.onUnauthorized = onUnauthorized
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder(purpose: .display) }
        viewController.onRetry = { [weak self] in self?.retry() }
    }

    /// - Parameter purpose: 電波の回復などでやり直すときは`.display`。レート制限で止められている間は送らない。
    @discardableResult
    func start(purpose: RequestPurpose = .action) -> Task<Void, Never>? {
        viewController?.setContentState(.loading)
        return run(purpose) { controller in
            do {
                guard let accounts = try await controller.store.loadInitial() else { return }
                controller.showEntries()
                controller.viewController?.setContentState(.loaded)
                controller.viewController?.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.logger.info("accountList loadInitial done count=\(accounts.count, privacy: .public)")
            } catch {
                controller.handle(error, during: "loadInitial") { controller.viewController?.setContentState(.failed($0)) }
            }
        }
    }

    /// 一覧を引っぱって離したときに、最初のページから読み直して置き換える。人の一覧は新しい人が上に来るとは限らず、上に足せないため。
    /// 読めなかったら、前の一覧のまま残す。最初の読み込みに失敗したままなら、それをやり直す。
    private func refresh() async {
        logger.info("accountList refresh")
        if case .failed = viewController?.contentState {
            await start()?.value
            return
        }
        do {
            guard let accounts = try await store.loadInitial() else { return }
            showEntries()
            viewController?.setFooterState(store.reachedEnd ? .reachedEnd : .idle)
            logger.info("accountList refresh done count=\(accounts.count, privacy: .public)")
        } catch {
            handle(error, during: "refresh") { _ in }
        }
    }

    private func retry() {
        if store.accounts.isEmpty {
            start()
        } else {
            loadOlder()
        }
    }

    private func loadOlder(purpose: RequestPurpose = .action) {
        guard !store.isLoading, !store.reachedEnd, !store.accounts.isEmpty else { return }
        viewController?.setFooterState(.loading)
        run(purpose) { controller in
            do {
                guard let added = try await controller.store.loadOlder() else { return }
                controller.showEntries()
                controller.viewController?.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.logger.info("accountList loadOlder done added=\(added.count, privacy: .public)")
            } catch {
                controller.handle(error, during: "loadOlder") { controller.viewController?.setFooterState(.failed($0)) }
            }
        }
    }

    @discardableResult
    private func run(_ purpose: RequestPurpose, _ operation: @escaping @MainActor (AccountListController) async -> Void) -> Task<Void, Never>? {
        // 作ったTaskは、作ったときのtask-localの値を引き継ぐ。
        RequestPurpose.$current.withValue(purpose) {
            tasks.run { [weak self] in
                guard let self else { return }
                await operation(self)
            }
        }
    }

    private func showEntries() {
        viewController?.setEntries(store.accounts.map(TimelineEntry.account))
    }

    private func handle(_ error: any Error, during operation: String, show: (ErrorPresentation) -> Void) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        logger.error("accountList \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized()
        }
        show(ErrorPresentation(error))
    }
}
