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
    private var streamingTask: Task<Void, Never>?
    /// 接続を始めるたびに増やす。止めた接続の終了の知らせが、後から始めた接続を消さないようにする。
    private var streamingGeneration = 0
    /// 最初の読み込みが済んだ。空のホームでも、済んでいればつなぐ。
    private var hasLoadedInitial = false
    /// バックグラウンドでは接続しない。最初の読み込みの途中でバックグラウンドへ入っても、読み込み後につながないようにする。
    private var isInForeground = true
    private var isSavingReadPosition = false
    /// バックグラウンドで既読位置の保存を終えるまで、アプリを止めないよう頼んでいる。
    private var readPositionBackgroundTask = UIBackgroundTaskIdentifier.invalid
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
        viewController.onGapSelect = { [weak self] id, direction in self?.loadGap(id, from: direction) }
    }

    func start() {
        guard !isStopped else { return }
        viewController.setContentState(.loading)
        run { await $0.loadInitial() }
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときに呼ぶ。
    func stop() {
        isStopped = true
        stopStreaming()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// バックグラウンドに入るときに呼ぶ。バックグラウンドでは接続が止められるため自分から切り、既読位置を保存する。
    func enterBackground() {
        isInForeground = false
        stopStreaming()
        saveReadPosition(inBackground: true)
    }

    /// バックグラウンドから戻ったときに呼ぶ。つなぎ直して切れていた間の投稿を補い、他の端末で読み進めた位置を取り込む。
    /// 最初の読み込みが済んでいなければ、済んだ時点でつなぐので何もしない。
    func enterForeground() {
        isInForeground = true
        guard hasLoadedInitial else { return }
        startStreaming()
        syncReadPosition()
    }

    private func stopStreaming() {
        guard let streamingTask else { return }
        logger.info("streaming stop")
        streamingTask.cancel()
        self.streamingTask = nil
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
            let markerID = try await loadMarker()
            guard let statuses = try await store.loadInitial(around: markerID), !isStopped else { return }
            // 前回読んだところから続きを読めるよう、既読位置の投稿を最上部に置く。新しい投稿はその上にある。
            let topID = markerID.flatMap { id in store.statuses.contains { $0.id == id } ? TimelineEntry.ID.status(id) : nil }
            viewController.setEntries(store.entries, placingAtTop: topID)
            updateUnreadCount()
            hasLoadedInitial = true
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
                controller.viewController.setEntries(controller.store.entries)
                controller.viewController.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.logger.info("home loadOlder done added=\(added.count, privacy: .public) reachedEnd=\(controller.store.reachedEnd, privacy: .public)")
            } catch {
                controller.handle(error, during: "loadOlder") { controller.viewController.setFooterState(.failed($0)) }
            }
        }
    }

    // MARK: - ストリーミング

    private func startStreaming() {
        guard !isStopped, isInForeground, streamingTask == nil else { return }
        streamingGeneration += 1
        let generation = streamingGeneration
        let client = client
        let streaming = streaming
        // 接続先はインスタンスの設定で変わりうるため、つなぐたびに調べる。
        let stream = ReconnectingStream {
            streaming.open(.user, baseURL: try await client.streamingURL())
        }
        let deliver: @Sendable (ReconnectingStream.Activity) async -> Void = { [weak self] activity in
            await self?.streamingDidChange(activity)
        }
        streamingTask = Task { [weak self] in
            do {
                try await stream.run(deliver)
            } catch {
                self?.streamingDidEnd(error, generation: generation)
            }
        }
    }

    private func streamingDidChange(_ activity: ReconnectingStream.Activity) {
        guard !isStopped else { return }
        switch activity {
        case .connected:
            logger.info("streaming connected")
            fillFromLatest()
        case .event(let event):
            receive(event)
        case .disconnected(let reason, let retryAfter):
            logger.info("streaming disconnected reason=\(reason, privacy: .public) retryAfter=\(retryAfter, privacy: .public)")
        }
    }

    /// トークンが無効になったときと、取り消したときだけ届く。
    private func streamingDidEnd(_ error: any Error, generation: Int) {
        if generation == streamingGeneration {
            streamingTask = nil
        }
        handle(error, during: "streaming") { _ in }
    }

    /// つながるたびに、切れていた間の投稿を読む。1ページに収まらなければギャップを置く。
    private func fillFromLatest() {
        run { controller in
            do {
                let before = controller.store.entries
                guard let added = try await controller.store.fillFromLatest(), !controller.isStopped else { return }
                controller.logger.info("home fill done added=\(added.count, privacy: .public) gaps=\(controller.store.gaps.count, privacy: .public)")
                // 待っている間に同じ投稿がストリーミングで挿入されていても、ギャップだけが増えていることがある。
                guard controller.store.entries != before else { return }
                controller.showEntries()
            } catch {
                // 失敗しても、次につながったときに同じ基準から読み直す。
                controller.handle(error, during: "fill") { _ in }
            }
        }
    }

    /// ギャップを1ページ分読む。読んでいる側に続く要素を基準にして、その位置を保つ。
    private func loadGap(_ id: String, from direction: TimelineStore.GapDirection) {
        guard !isStopped, let index = store.entries.firstIndex(where: { $0.id == .gap(id) }) else { return }
        let neighborIndex = direction == .fromOlder ? store.entries.index(after: index) : store.entries.index(before: index)
        let anchorID = store.entries.indices.contains(neighborIndex) ? store.entries[neighborIndex].id : nil
        viewController.setLoadingGaps(store.loadingGapIDs.union([id]))
        run { controller in
            controller.logger.info("home loadGap start id=\(id, privacy: .public) direction=\(String(describing: direction), privacy: .public)")
            do {
                guard let added = try await controller.store.loadGap(id, from: direction), !controller.isStopped else { return }
                controller.viewController.setLoadingGaps(controller.store.loadingGapIDs)
                controller.viewController.setEntries(controller.store.entries, keeping: anchorID)
                controller.updateUnreadCount()
                controller.logger.info("home loadGap done added=\(added.count, privacy: .public)")
            } catch {
                controller.viewController.setLoadingGaps(controller.store.loadingGapIDs)
                controller.handle(error, during: "loadGap") { _ in }
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
            showEntries()
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
        saveReadPosition(inBackground: false)
        guard isWaitingForScrollToSettle else { return }
        isWaitingForScrollToSettle = false
        insertPending()
    }

    // MARK: - 既読位置

    /// 既読位置はタイムラインを読む助けで、読めなくてもタイムラインは表示できるため、トークンの失効以外の失敗では位置なしで進める。
    private func loadMarker() async throws -> String? {
        do {
            return try await client.homeMarker()
        } catch let error as MastodonAPIError where error.isUnauthorized {
            throw error
        } catch {
            logger.error("home marker load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func syncReadPosition() {
        run { controller in
            do {
                guard let markerID = try await controller.client.homeMarker(), !controller.isStopped else { return }
                controller.store.applySavedMarker(markerID)
                controller.updateUnreadCount()
                controller.logger.info("home marker synced id=\(markerID, privacy: .public)")
            } catch {
                controller.handle(error, during: "marker sync") { _ in }
            }
        }
    }

    /// 既読位置が保存済みより進んでいれば保存する。保存している間に読み進めた分も、続けて保存する。
    /// 競合などで失敗したら、次にスクロールが止まったときに保存し直す。
    private func saveReadPosition(inBackground: Bool) {
        guard !isStopped, store.readIDToSave != nil || isSavingReadPosition else { return }
        if inBackground, readPositionBackgroundTask == .invalid {
            // バックグラウンドに入るときは、保存し終えるまでアプリを止めないよう頼んでおく。保存中の分も含める。
            readPositionBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "save home marker") { [weak self] in
                self?.endReadPositionBackgroundTask()
            }
        }
        guard !isSavingReadPosition else { return }
        isSavingReadPosition = true
        let client = client
        Task { [weak self] in
            while let self, !self.isStopped, let id = self.store.readIDToSave {
                do {
                    try await client.saveHomeMarker(lastReadID: id)
                    self.store.markSaved(id)
                    self.logger.info("home marker saved id=\(id, privacy: .public)")
                } catch {
                    self.handle(error, during: "marker save") { _ in }
                    break
                }
            }
            self?.isSavingReadPosition = false
            self?.endReadPositionBackgroundTask()
        }
    }

    private func endReadPositionBackgroundTask() {
        guard readPositionBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(readPositionBackgroundTask)
        readPositionBackgroundTask = .invalid
    }

    private func insertPending() {
        guard !isStopped else { return }
        let added = store.flushPending()
        logger.info("home insert pending added=\(added.count, privacy: .public)")
        guard !added.isEmpty else { return }
        showEntries()
    }

    private func showEntries() {
        viewController.setEntries(store.entries)
        updateUnreadCount()
    }

    private func markRead(_ ids: [Status.ID]) {
        store.markRead(ids)
        updateUnreadCount()
    }

    private func updateUnreadCount() {
        viewController.setUnreadCount(store.unreadCount, isLowerBound: store.hasUnloadedUnread)
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
