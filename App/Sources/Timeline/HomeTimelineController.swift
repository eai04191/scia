import Foundation
import os
import SciaCore
import UIKit

/// ホームタイムラインの読み込みとストリーミングを、TimelineViewControllerの表示へつなぐ。
@MainActor
final class HomeTimelineController {
    /// 1回に読む件数。APIの上限が40件。
    private static let pageSize = 40

    let viewController = TimelineViewController()
    private let store: TimelineStore
    private let client: MastodonClient
    private let streaming: StreamingClient
    private let tuning: TuningStore
    /// トークンが無効だったとき、どのコントローラーからの通知かを添えて呼ぶ。
    private let onUnauthorized: (HomeTimelineController, String) -> Void
    private let logger = SciaLog.logger(category: "timeline")
    private var tasks: [Task<Void, Never>] = []
    private var isStopped = false
    private var isStreaming = false
    /// 新着を挿入する時機が来たが、指でスクロール中なので止まるのを待っている。
    private var isWaitingForScrollToSettle = false

    init(
        client: MastodonClient,
        streaming: StreamingClient,
        tuning: TuningStore = AppDependencies.tuning,
        onUnauthorized: @escaping (HomeTimelineController, String) -> Void
    ) {
        store = TimelineStore(pageSize: Self.pageSize) { query in
            try await client.homeTimeline(query)
        }
        self.client = client
        self.streaming = streaming
        self.tuning = tuning
        self.onUnauthorized = onUnauthorized
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder() }
        viewController.onRetry = { [weak self] in self?.retry() }
        viewController.onVisibleStatusesChange = { [weak self] ids in self?.markRead(ids) }
        viewController.onScrollSettle = { [weak self] in self?.scrollDidSettle() }
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
            startStreaming()
        } catch {
            handle(error, during: "loadInitial") { viewController.setContentState(.failed($0)) }
        }
    }

    private func loadOlder() {
        guard !isStopped, !store.isLoading, !store.reachedEnd, !store.statuses.isEmpty else { return }
        viewController.setFooterState(.loading)
        run { controller in
            controller.logger.info("home loadOlder start")
            do {
                guard let added = try await controller.store.loadOlder(), !controller.isStopped else { return }
                controller.viewController.setStatuses(controller.store.statuses)
                controller.viewController.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.logger.info("home loadOlder done added=\(added.count, privacy: .public) reachedEnd=\(controller.store.reachedEnd, privacy: .public)")
            } catch {
                controller.handle(error, during: "loadOlder") { controller.viewController.setFooterState(.failed($0)) }
            }
        }
    }

    // MARK: - ストリーミング

    private func startStreaming() {
        guard !isStopped, !isStreaming else { return }
        isStreaming = true
        run { controller in
            do {
                let baseURL = try await controller.client.streamingURL()
                let connection = controller.streaming.open(.user, baseURL: baseURL)
                controller.logger.info("streaming open")
                try await withTaskCancellationHandler {
                    while true {
                        let event = try await connection.next()
                        controller.receive(event)
                    }
                } onCancel: {
                    connection.close()
                }
            } catch {
                controller.isStreaming = false
                // 再接続は切断と復帰の処理で行う。ここでは止まったことだけ記録する。
                controller.handle(error, during: "streaming") { _ in }
            }
        }
    }

    private func receive(_ event: StreamingEvent) {
        guard !isStopped else { return }
        switch store.receive(event) {
        case .none:
            break
        case .pendingStarted:
            scheduleInsertion()
        case .entriesChanged:
            viewController.setStatuses(store.statuses)
            viewController.setUnreadCount(store.unreadCount)
        }
    }

    /// 最初の新着が届いてから間隔をおいて、溜まった新着をまとめて挿入する。
    private func scheduleInsertion() {
        let interval = tuning.value(of: TuningCatalog.insertionInterval)
        run { controller in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            if controller.viewController.isUserScrolling {
                // 指の動きと関係なく画面が動かないよう、スクロールが止まってから挿入する。
                controller.isWaitingForScrollToSettle = true
            } else {
                controller.insertPending()
            }
        }
    }

    private func scrollDidSettle() {
        guard isWaitingForScrollToSettle else { return }
        isWaitingForScrollToSettle = false
        insertPending()
    }

    private func insertPending() {
        guard !isStopped else { return }
        let added = store.flushPending()
        logger.info("home insert pending added=\(added.count, privacy: .public)")
        guard !added.isEmpty else { return }
        viewController.setStatuses(store.statuses)
        viewController.setUnreadCount(store.unreadCount)
    }

    private func markRead(_ ids: [Status.ID]) {
        store.markRead(ids)
        viewController.setUnreadCount(store.unreadCount)
    }

    private func handle(_ error: any Error, during operation: String, show: (String) -> Void) {
        // 止めた後に届いた結果や、止めたことによる取り消しは、もう画面に関係しない。
        guard !isStopped, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        logger.error("home \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized(self, "ログインの有効期限が切れたか、アプリの許可が取り消されました。ログインし直してください。")
        } else {
            show(error.localizedDescription)
        }
    }
}
