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
    /// 近づいたときの自動の読み込みに失敗した、または進まなかったギャップ。読み直し続けないよう、タップされるまで自動では読まない。
    private var autoLoadFailedGapIDs: Set<String> = []
    private var isSavingReadPosition = false
    /// バックグラウンドで既読位置の保存を終えるまで、アプリを止めないよう頼んでいる。
    private var readPositionBackgroundTask = UIBackgroundTaskIdentifier.invalid
    /// 新着を挿入する時機が来たが、スクロールや長押しのメニューなどの操作中なので、終わるのを待っている。
    private var isWaitingForInteractionToSettle = false

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
        viewController.onInteractionSettle = { [weak self] in self?.interactionDidSettle() }
        viewController.onGapSelect = { [weak self] id, direction in self?.loadGap(id, from: direction, isAutomatic: false) }
        viewController.onGapApproach = { [weak self] id, direction in self?.loadGap(id, from: direction, isAutomatic: true) }
        #if DEBUG
        viewController.debugActions = makeDebugActions()
        #endif
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
                let maxPages = Int(controller.tuning.value(of: TuningCatalog.fillPageLimit))
                guard let added = try await controller.store.fillFromLatest(maxPages: maxPages), !controller.isStopped else { return }
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
    /// - Parameter isAutomatic: 近づいたことによる読み込み。失敗したギャップは、タップされるまで自動では読まない。
    private func loadGap(_ id: String, from direction: TimelineStore.GapDirection, isAutomatic: Bool) {
        if isAutomatic {
            guard !autoLoadFailedGapIDs.contains(id) else { return }
        } else {
            autoLoadFailedGapIDs.remove(id)
        }
        guard !isStopped, !store.loadingGapIDs.contains(id), let index = store.entries.firstIndex(where: { $0.id == .gap(id) }) else { return }
        let neighborIndex = direction == .fromOlder ? store.entries.index(after: index) : store.entries.index(before: index)
        let anchorID = store.entries.indices.contains(neighborIndex) ? store.entries[neighborIndex].id : nil
        viewController.setLoadingGaps(store.loadingGapIDs.union([id]))
        let gapBefore = store.gaps.first { $0.id == id }
        run { controller in
            controller.logger.info("home loadGap start id=\(id, privacy: .public) direction=\(String(describing: direction), privacy: .public) automatic=\(isAutomatic, privacy: .public)")
            do {
                let added = try await controller.store.loadGap(id, from: direction)
                guard !controller.isStopped else { return }
                // 再生成中の空の結果などでギャップが縮まなければ、描き直しの後にすぐ同じギャップを読み直してしまうため、
                // 失敗と同じくタップされるまで自動では読まない。
                if isAutomatic, added?.isEmpty == true, controller.store.gaps.contains(where: { $0 == gapBefore }) {
                    controller.autoLoadFailedGapIDs.insert(id)
                }
                controller.viewController.setLoadingGaps(controller.store.loadingGapIDs)
                guard let added else { return }
                controller.viewController.setEntries(controller.store.entries, keeping: anchorID)
                controller.updateUnreadCount()
                controller.logger.info("home loadGap done added=\(added.count, privacy: .public)")
            } catch {
                if isAutomatic {
                    controller.autoLoadFailedGapIDs.insert(id)
                }
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
            if controller.viewController.isUserInteracting {
                // 指の動きと関係なく画面が動かないよう、スクロールや長押しのメニューなどの操作が終わってから挿入する。
                controller.isWaitingForInteractionToSettle = true
            } else {
                controller.insertPending()
            }
        }
    }

    private func interactionDidSettle() {
        saveReadPosition(inBackground: false)
        guard isWaitingForInteractionToSettle else { return }
        isWaitingForInteractionToSettle = false
        insertPending()
    }

    // MARK: - 既読位置

    /// 既読位置はタイムラインを読む助けで、読めなくてもタイムラインは表示できるため、トークンの失効以外の失敗では位置なしで進める。
    private func loadMarker() async throws -> String? {
        do {
            return try await client.marker(for: .home)
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
                guard let markerID = try await controller.client.marker(for: .home), !controller.isStopped else { return }
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
                    try await client.saveMarker(for: .home, lastReadID: id)
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

    /// 投稿とそれをブーストした投稿の中身を変え、表示に関わる変化があれば描き直す。お気に入りなどの操作の結果を反映する。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard !isStopped, store.updateStatus(id, transform) else { return }
        showEntries()
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

#if DEBUG
// MARK: - 検証用

extension HomeTimelineController {
    /// 投稿しなくても、新着の挿入やギャップの表示をシミュレーターで確かめるための操作。
    fileprivate func makeDebugActions() -> [UIAction] {
        [
            UIAction(title: "ダミーの新着を流す", image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                self?.streamDummyArrivals(count: 10)
            },
            UIAction(title: "画像付きのダミー投稿を流す", image: UIImage(systemName: "photo.badge.plus")) { [weak self] _ in
                self?.streamDummyMediaStatus()
            },
            UIAction(title: "直近の投稿を取りこぼして再接続", image: UIImage(systemName: "bolt.horizontal")) { [weak self] _ in
                self?.simulateMissedWhileDisconnected()
            },
        ]
    }

    /// ストリーミングで届いたのと同じ経路で、ダミーの新着を少しずつ流す。
    ///
    /// ダミーはサーバーにない投稿なので、見れば手元では既読になるが、サーバーに保存する既読位置には使わない。
    /// IDはMastodonと同じく時刻から作るため、後から届く本物の投稿はダミーより新しく並び、補完もダミー以降を読む。
    private func streamDummyArrivals(count: Int) {
        let avatar = store.statuses.first?.account.avatar ?? client.credential.instance
        run { controller in
            for number in 1...count {
                guard !controller.isStopped else { return }
                let dummy = Self.dummyStatus(number: number, avatar: avatar)
                controller.store.debugLocalOnlyIDs.insert(dummy.id)
                controller.receive(.update(dummy))
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// ビューアを確かめるための、形の違う画像を4枚付けたダミーの投稿を、新着と同じ経路で1件流す。
    /// 画像は端末で描くため、通信せず、実際の投稿を探さずに確かめられる。
    private func streamDummyMediaStatus() {
        let avatar = store.statuses.first?.account.avatar ?? client.credential.instance
        let base = Self.dummyStatus(number: 1, avatar: avatar)
        let dummy = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（画像）", avatar: avatar),
            content: "ビューアの確認用に4枚の画像を添付",
            spoilerText: "",
            url: nil,
            mediaAttachments: DummyMedia.attachments(idPrefix: base.id)
        )
        run { controller in
            controller.store.debugLocalOnlyIDs.insert(dummy.id)
            controller.receive(.update(dummy))
        }
    }

    /// 補完で続けて読む上限より多い数の最新の投稿を忘れてからつなぎ直し、実データで補完とギャップを起こす。
    /// 補完の基準が残るよう、先に古いページを読み足し、少なくとも1件は残す。読み足しは接続を止める前に行い、失敗しても接続は止めない。
    private func simulateMissedWhileDisconnected() {
        let targetCount = Self.pageSize * Int(tuning.value(of: TuningCatalog.fillPageLimit)) + 10
        run { controller in
            do {
                while controller.store.statuses.count <= targetCount, !controller.store.reachedEnd {
                    // 再生成中は空のページが返り続けるため、増えなければやめる。
                    guard let added = try await controller.store.loadOlder(), !added.isEmpty else { break }
                }
            } catch {
                controller.handle(error, during: "debug loadOlder") { _ in }
                return
            }
            let forgetCount = min(targetCount, controller.store.statuses.count - 1)
            guard !controller.isStopped, forgetCount > 0 else { return }
            controller.logger.info("debug forget newest count=\(forgetCount, privacy: .public)")
            controller.stopStreaming()
            controller.store.debugForgetNewest(forgetCount)
            controller.showEntries()
            controller.startStreaming()
        }
    }

    private static let dummyBodies = [
        "短いダミーの新着",
        "二行くらいになるダミーの新着です。挿入されたときに、読んでいる位置が動かないかを確かめるために、少し長めにしています。",
        "<p>段落が分かれたダミーの新着。</p><p>" + String(repeating: "ストリーミングで新着が流れてきても、読んでいる位置が動かないことを確かめる。", count: 4) + "</p>",
    ]

    private static func dummyStatus(number: Int, avatar: URL) -> Status {
        // Mastodonの投稿IDと同じく、ミリ秒の時刻を16ビット左へずらし、下位に連番を入れる。
        let milliseconds = UInt64(Date.now.timeIntervalSince1970 * 1000)
        return Status(
            id: String(milliseconds << 16 | UInt64(number & 0xFFFF)),
            createdAt: .now,
            account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー #\(number)", avatar: avatar),
            content: dummyBodies[number % dummyBodies.count],
            spoilerText: "",
            url: nil
        )
    }
}
#endif
