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
    private var tasks: [Task<Void, Never>] = []

    static func make(kind: AccountListKind, client: MastodonClient, onUnauthorized: @escaping () -> Void) -> (AccountListController, TimelineViewController) {
        let viewController = TimelineViewController(texts: .accountList(kind))
        let controller = AccountListController(kind: kind, client: client, viewController: viewController, onUnauthorized: onUnauthorized)
        viewController.lifetimeOwner = controller
        return (controller, viewController)
    }

    private init(kind: AccountListKind, client: MastodonClient, viewController: TimelineViewController, onUnauthorized: @escaping () -> Void) {
        let pageSize = Self.pageSize
        store = AccountListStore(kind: kind) { maxID in
            try await client.accounts(in: kind, maxID: maxID, limit: pageSize)
        }
        self.viewController = viewController
        self.onUnauthorized = onUnauthorized
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder(origin: .automatic) }
        viewController.onRetry = { [weak self] in self?.retry() }
    }

    isolated deinit {
        tasks.forEach { $0.cancel() }
    }

    /// - Parameter origin: 電波の回復などでやり直すときは`.automatic`。レート制限で止められている間は送らない。
    func start(origin: RequestOrigin = .user) {
        viewController?.setContentState(.loading)
        run(origin) { controller in
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

    private func retry() {
        if store.accounts.isEmpty {
            start()
        } else {
            loadOlder()
        }
    }

    private func loadOlder(origin: RequestOrigin = .user) {
        guard !store.isLoading, !store.reachedEnd, !store.accounts.isEmpty else { return }
        viewController?.setFooterState(.loading)
        run(origin) { controller in
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

    private func run(_ origin: RequestOrigin, _ operation: @escaping @MainActor (AccountListController) async -> Void) {
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
