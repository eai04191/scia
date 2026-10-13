import Foundation
import os
import SciaCore
import UIKit

/// ホームタイムラインの読み込みを、TimelineViewControllerの表示へつなぐ。
@MainActor
final class HomeTimelineController {
    /// 1回に読む件数。APIの上限が40件。
    private static let pageSize = 40

    let viewController = TimelineViewController()
    private let store: TimelineStore
    /// トークンが無効だったとき、どのコントローラーからの通知かを添えて呼ぶ。
    private let onUnauthorized: (HomeTimelineController, String) -> Void
    private let logger = SciaLog.logger(category: "timeline")
    private var tasks: [Task<Void, Never>] = []
    private var isStopped = false

    init(client: MastodonClient, onUnauthorized: @escaping (HomeTimelineController, String) -> Void) {
        store = TimelineStore { maxID in
            try await client.homeTimeline(maxID: maxID, limit: Self.pageSize)
        }
        self.onUnauthorized = onUnauthorized
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder() }
        viewController.onRetry = { [weak self] in self?.retry() }
    }

    func start() {
        guard !isStopped else { return }
        viewController.setContentState(.loading)
        run { await $0.loadInitial() }
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときに呼ぶ。
    func stop() {
        isStopped = true
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func run(_ operation: @escaping @MainActor (HomeTimelineController) async -> Void) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(Task { [weak self] in
            guard let self else { return }
            await operation(self)
        })
    }

    private func retry() {
        if store.statuses.isEmpty {
            start()
        } else {
            loadOlder()
        }
    }

    private func loadInitial() async {
        logger.info("home loadInitial start")
        do {
            guard let statuses = try await store.loadInitial(), !isStopped else { return }
            viewController.setStatuses(statuses)
            viewController.setContentState(statuses.isEmpty && store.isRegenerating ? .regenerating : .loaded)
            viewController.setFooterState(store.reachedEnd ? .reachedEnd : .idle)
            logger.info("home loadInitial done count=\(statuses.count, privacy: .public) regenerating=\(self.store.isRegenerating, privacy: .public)")
        } catch {
            handle(error) { viewController.setContentState(.failed($0)) }
        }
    }

    private func loadOlder() {
        guard !isStopped, !store.isLoading, !store.reachedEnd, !store.statuses.isEmpty else { return }
        viewController.setFooterState(.loading)
        run { controller in
            controller.logger.info("home loadOlder start")
            do {
                guard let added = try await controller.store.loadOlder(), !controller.isStopped else { return }
                controller.viewController.appendStatuses(added)
                controller.viewController.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.logger.info("home loadOlder done added=\(added.count, privacy: .public) reachedEnd=\(controller.store.reachedEnd, privacy: .public)")
            } catch {
                controller.handle(error) { controller.viewController.setFooterState(.failed($0)) }
            }
        }
    }

    private func handle(_ error: any Error, show: (String) -> Void) {
        // 止めた後に届いた結果や、止めたことによる取り消しは、もう画面に関係しない。
        guard !isStopped, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        logger.error("home load failed: \(error.localizedDescription, privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized(self, "ログインの有効期限が切れたか、アプリの許可が取り消されました。ログインし直してください。")
        } else {
            show(error.localizedDescription)
        }
    }
}
