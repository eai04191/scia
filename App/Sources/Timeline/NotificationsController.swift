import Foundation
import os
import SciaCore
import UIKit

/// 通知の読み込みとストリーミングを、TimelineViewControllerの表示へつなぐ。
@MainActor
final class NotificationsController {
    /// 1回に読む件数。ホームと揃える。
    private static let pageSize = 40

    let viewController = TimelineViewController(texts: .notifications)
    /// 未読の数が変わったときに呼ぶ。タブのバッジに出す。2つめの値は、実際はもっと多いかもしれないこと。
    var onUnreadCountChange: ((Int, Bool) -> Void)?
    /// ストリーミングで新しい通知が届いたときに呼ぶ。ステータスバーに流す。2つめの値は、通知の投稿に当てたサーバーのフィルターの判定。
    var onArrival: ((MastodonNotification, FilterVerdict) -> Void)?
    /// 通知の投稿に当てるサーバーのフィルター。ステータスバーに流す通知にも、一覧と同じく当てる。
    private let filtering: StatusFiltering
    private let store: NotificationStore
    private let client: MastodonClient
    private let streamingHub: StreamingHub
    private let tuning: TuningStore
    /// APIが401を返したときに呼ぶ。トークンが無効かを確かめ、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "notifications")
    private var tasks: [Task<Void, Never>] = []
    private var isStopped = false
    /// 設定で無効にしている。購読せず、有効に戻したらつなぎ直して、無効だった間を補う。
    private var isDisabled = false
    /// `user`ストリームの購読。読み込みが済んでから申し込み、止めるときやバックグラウンドではやめる。
    private var streamingSubscription: StreamingHub.Subscription?
    /// 一覧を最上部からさらに引っぱったときに見せる、ストリーミングの状態。
    private let streamingStatusView = StreamingStatusPullView()
    /// 切れていた間の通知を読む補完の状態。ストリーミングの状態と並べて、引っぱったときに見せる。
    private var catchUp = CatchUpStatus()
    /// ストリーミングで届いた通知の流れの速さ。引っぱったときに見せる。
    private var arrivalRate = ArrivalRate()
    private var hasLoadedInitial = false
    private var isInForeground = true
    private var isSavingReadPosition = false
    private var readPositionBackgroundTask = UIBackgroundTaskIdentifier.invalid
    private var isWaitingForInteractionToSettle = false
    #if DEBUG
    /// 新着の挿入を保留している間に、補完を見送った。保留を解いたときに補完する。
    private var isFillHeld = false
    #endif

    init(
        client: MastodonClient,
        streamingHub: StreamingHub,
        tuning: TuningStore = AppDependencies.tuning,
        onUnauthorized: @escaping () -> Void
    ) {
        let filtering = StatusFiltering(context: .notifications, myAccountID: client.credential.accountID)
        self.filtering = filtering
        store = NotificationStore(pageSize: Self.pageSize, filtering: filtering) { query in
            try await client.notifications(query)
        }
        self.client = client
        self.streamingHub = streamingHub
        self.tuning = tuning
        self.onUnauthorized = onUnauthorized
        viewController.filterWarnings = FilterWarnings(filtering: filtering)
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder(origin: .automatic) }
        viewController.onRetry = { [weak self] in self?.retry() }
        viewController.onVisibleNotificationsChange = { [weak self] ids in self?.markRead(ids) }
        viewController.onInteractionSettle = { [weak self] in self?.interactionDidSettle() }
        streamingStatusView.install(in: viewController.collectionView)
    }

    /// - Parameter origin: 電波の回復などでやり直すときは`.automatic`。レート制限で止められている間は送らない。
    func start(origin: RequestOrigin = .user) {
        guard !isStopped else { return }
        hasStarted = true
        viewController.setContentState(.loading)
        run(origin) { await $0.loadInitial() }
    }

    private var hasStarted = false

    /// まだ始めていなければ始める。無効にしていて起動のときに始めなかった通知を、有効にしたときに始めるのに使う。
    func startIfNeeded() {
        guard !hasStarted else { return }
        start()
    }

    /// 設定で有効か無効かを切り替える。無効にしたら購読をやめ、有効に戻したら、読み込み済みならつなぎ直す。
    func setEnabled(_ isEnabled: Bool) {
        guard isDisabled == isEnabled else { return }
        isDisabled = !isEnabled
        if isDisabled {
            stopStreaming()
        } else if hasLoadedInitial {
            startStreaming()
        }
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときに呼ぶ。
    func stop() {
        isStopped = true
        stopStreaming()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// バックグラウンドに入るときに呼ぶ。接続を切り、既読位置を保存する。
    func enterBackground() {
        isInForeground = false
        stopStreaming()
        saveReadPosition(inBackground: true)
    }

    /// バックグラウンドから戻ったときに呼ぶ。つなぎ直して切れていた間の通知を補い、他の端末で読み進めた位置を取り込む。
    func enterForeground() {
        isInForeground = true
        guard !isStopped else { return }
        // バックグラウンドにいる間に電波が戻ったり、レート制限が明けたりしても、その知らせでは読み込まない。戻ったここでやり直す。
        retryFailedLoads()
        guard hasLoadedInitial else { return }
        startStreaming()
        syncReadPosition()
    }

    /// - Parameter origin: 自動の読み込みなら`.automatic`。レート制限で止められている間は送らずに失敗させる。
    private func run(_ origin: RequestOrigin = .user, _ operation: @escaping @MainActor (NotificationsController) async -> Void) {
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
        if store.isEmpty {
            start()
        } else {
            loadOlder()
        }
    }

    private func loadInitial() async {
        logger.info("notifications loadInitial start")
        do {
            let markerID = try await loadMarker()
            guard let notifications = try await store.loadInitial(markerID: markerID), !isStopped else { return }
            showEntries()
            hasLoadedInitial = true
            updateCatchUp { $0.finish(at: Date()) }
            viewController.setContentState(.loaded)
            viewController.setFooterState(store.reachedEnd ? .reachedEnd : .idle)
            logger.info("notifications loadInitial done count=\(notifications.count, privacy: .public)")
            startStreaming()
        } catch {
            handle(error, during: "loadInitial") { viewController.setContentState(.failed($0)) }
        }
    }

    private func loadOlder(origin: RequestOrigin = .user) {
        guard !isStopped, !store.isLoading, !store.reachedEnd, !store.isEmpty else { return }
        viewController.setFooterState(.loading)
        run(origin) { controller in
            do {
                guard let added = try await controller.store.loadOlder(), !controller.isStopped else { return }
                controller.showEntries()
                controller.viewController.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                controller.logger.info("notifications loadOlder done added=\(added.count, privacy: .public)")
            } catch {
                controller.handle(error, during: "loadOlder") { controller.viewController.setFooterState(.failed($0)) }
            }
        }
    }

    // MARK: - ストリーミング

    private func startStreaming() {
        guard !isStopped, !isDisabled, isInForeground, streamingSubscription == nil else { return }
        streamingSubscription = streamingHub.subscribe(.user) { [weak self] activity in
            self?.streamingDidChange(activity)
        }
    }

    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。失敗したままの読み込みと、切れているストリーミングをすぐやり直す。
    func recover() {
        guard !isStopped, isInForeground else { return }
        // 切れていれば、セッションがつなぎ直させ、つながったところで切れていた間を補う。
        if hasLoadedInitial, !isDisabled, streamingHub.isConnected {
            // つながったときの補完が、止められている間や電波のない間に失敗していることがある。
            fillFromLatest()
        }
        retryFailedLoads()
    }

    /// 失敗したままの最初の読み込みか、末尾の読み込みをやり直す。最初の読み込みが済めば、そこでつなぐ。
    private func retryFailedLoads() {
        if case .failed = viewController.contentState {
            start(origin: .automatic)
        } else if case .failed = viewController.footerState {
            loadOlder(origin: .automatic)
        }
    }

    /// ストリーミングの接続の状態を、引っぱったときに見せる表示へ伝える。
    func showStreamingState(_ state: ConnectionDiagnostics.StreamingState?) {
        streamingStatusView.setState(state)
    }

    /// 補完で429や503を受けて止められていたら、待機中と出す。補完の終わりの反映を待たせないよう、別に確かめる。
    private func showPauseAfterFill() {
        let attempt = catchUp.attempt
        run(.automatic) { controller in
            guard let until = await controller.client.automaticRequestsPausedUntil() else { return }
            controller.updateCatchUp { $0.pause(after: attempt, until: until) }
        }
    }

    private func updateCatchUp(_ change: (inout CatchUpStatus) -> Void) {
        change(&catchUp)
        streamingStatusView.setCatchUp(catchUp)
    }

    private func stopStreaming() {
        guard let streamingSubscription else { return }
        logger.info("notifications streaming unsubscribe")
        streamingSubscription.cancel()
        self.streamingSubscription = nil
        // 購読をやめた後は知らせが届かないので、出していた表示を消す。
        viewController.setOutageNotice(false)
    }

    private func streamingDidChange(_ activity: StreamingHub.Activity) {
        guard !isStopped else { return }
        switch activity {
        case .connected:
            logger.info("notifications streaming connected")
            fillFromLatest()
        case .event(.notification(let notification)):
            receive(notification)
        case .event:
            break
        case .poll:
            logger.info("notifications poll")
            fillFromLatest()
        case .outage(let isOngoing):
            viewController.setOutageNotice(isOngoing)
        }
    }

    private func receive(_ notification: MastodonNotification) {
        arrivalRate.record(at: Date())
        streamingStatusView.setArrivalRate(arrivalRate)
        // receiveの戻り値は、保留が空から1件になったかで、受け取ったかではない。挿入を待つ間に続けて届いた通知も流すよう、保留が増えたかで見る。
        let pendingCount = store.pending.count
        if store.receive(notification) {
            scheduleInsertion()
        }
        if store.pending.count > pendingCount {
            onArrival?(notification, notification.status.map { filtering.verdict(for: $0) } ?? .none)
        }
        // 挿入までに読み終えられるよう、届いたらすぐアイコンを読み始める。
        viewController.prefetchAvatars(for: store.pending.map(TimelineEntry.notification))
    }

    #if DEBUG
    /// `scia-debug://inject/notifications`で読んだ通知を、ストリーミングで届いた通知と同じ経路で流す。サーバーにない通知なので、既読位置と補完の基準には使わない。
    func inject(_ notifications: [MastodonNotification]) {
        guard !isStopped else { return }
        logger.info("debug inject notifications count=\(notifications.count, privacy: .public)")
        for notification in notifications {
            store.debugLocalOnlyIDs.insert(notification.id)
            receive(notification)
        }
    }
    #endif

    /// つながるたびと、つながらない間のポーリングで、切れていた間の通知を読む。
    private func fillFromLatest() {
        #if DEBUG
        // 補完で読んだ新着はストアへ直接合流し、insertPendingの保留を通らないため、保留中は補完を始めない。
        // 保留を送る前に始まった補完は止めない。その結果は、保留中でも一覧に入る。
        if DebugFaults.isHoldingArrivals {
            isFillHeld = true
            logger.info("notifications fill held")
            return
        }
        #endif
        run(.automatic) { controller in
            do {
                let before = controller.store.entries
                let maxPages = Int(controller.tuning.value(of: TuningCatalog.fillPageLimit))
                controller.logger.info("notifications fill start")
                // 呼んだ時点ではなく読み始める直前に変える。呼んでから読み始めるまでに前の補完が終わると、その終わりで戻ってしまうため。
                // 補完の最中ならストアはnilを返し、今の補完が続けて読むので、その終わりで状態を戻す。
                controller.updateCatchUp { $0.begin() }
                guard let added = try await controller.store.fillFromLatest(maxPages: maxPages, progress: { count in
                    controller.updateCatchUp { $0.progress(readCount: count) }
                }), !controller.isStopped else { return }
                controller.updateCatchUp { $0.finish(at: Date()) }
                controller.showPauseAfterFill()
                controller.logger.info("notifications fill done added=\(added.count, privacy: .public)")
                // 待っている間に同じ通知がストリーミングで挿入されていても、古い側を捨てていることがある。
                // 読めなかった通知だけが増えたときも描き直すよう、表示する並びで比べる。
                guard controller.store.entries != before else { return }
                controller.showEntries()
                controller.viewController.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
            } catch {
                // 失敗しても、次につながったときに同じ基準から読み直す。
                controller.updateCatchUp { $0.fail(error) }
                controller.showPauseAfterFill()
                controller.handle(error, during: "fill") { _ in }
            }
        }
    }

    /// 最初の通知が届いてから間隔をおいて、溜まった通知をまとめて挿入する。ホームと同じ間隔を使う。
    /// 挿入する前に、ホームと同じく、通知のアイコンが読み込み終わるのを上限まで待つ。
    private func scheduleInsertion() {
        let interval = tuning.value(of: TuningCatalog.insertionInterval)
        run { controller in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            let wait = Duration.seconds(controller.tuning.value(of: TuningCatalog.arrivalAvatarWait))
            await controller.viewController.waitForAvatars(of: { controller.store.pending.map(TimelineEntry.notification) }, within: wait)
            guard !Task.isCancelled else { return }
            if controller.viewController.isUserInteracting {
                controller.isWaitingForInteractionToSettle = true
            } else {
                controller.insertPending()
            }
        }
    }

    #if DEBUG
    /// `scia-debug://arrivals/release`で保留を解いたとき、見送った補完を始め、溜まった新着を挿入する。指で操作している最中なら、操作が終わってから挿入する。
    func releaseHeldArrivals() {
        if isFillHeld {
            isFillHeld = false
            fillFromLatest()
        }
        if viewController.isUserInteracting {
            isWaitingForInteractionToSettle = true
        } else {
            insertPending()
        }
    }
    #endif

    private func interactionDidSettle() {
        saveReadPosition(inBackground: false)
        guard isWaitingForInteractionToSettle else { return }
        isWaitingForInteractionToSettle = false
        insertPending()
    }

    /// 通知の対象の投稿の中身を変え、表示に関わる変化があれば描き直す。お気に入りなどの操作の結果を反映する。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard !isStopped, store.updateStatus(id, transform) else { return }
        showEntries()
    }

    /// 削除した投稿についての通知を除く。
    func removeStatus(_ id: Status.ID) {
        guard !isStopped, store.removeStatus(id) else { return }
        showEntries(animatesRemoval: true)
    }

    /// ミュートしたハッシュタグの付いた投稿の通知を除き、あとから届いても足さない。使う人の操作の結果なので、閉じる動きで消す。
    func setTag(_ name: String, excluded: Bool) {
        guard !isStopped else { return }
        guard excluded else {
            store.includeTag(name)
            return
        }
        guard store.excludeTag(name) else { return }
        showEntries(animatesRemoval: true)
    }

    /// 通知を隠すミュートか、ブロックをした相手からの通知を除き、あとから届いても足さない。使う人の操作の結果なので、閉じる動きで消す。
    /// 解除したら、また足すようにする。除いた通知は、読み込み直すまで戻さない。
    func setAccount(_ id: String, excluded: Bool) {
        guard !isStopped else { return }
        guard excluded else {
            store.includeAccount(id)
            return
        }
        guard store.excludeAccount(id) else { return }
        showEntries(animatesRemoval: true)
    }

    /// 使う人が削除した通知を除く。まとまりなら、キーでまとまりごと除く。
    func removeNotification(_ notification: MastodonNotification) {
        guard !isStopped, store.removeNotification(notification.id, groupKey: notification.groupKey) else { return }
        showEntries(animatesRemoval: true)
    }

    /// 片づけたフォローリクエストの通知と、同じユーザーからのリクエストの通知を除く。承認か却下が済んだときに呼ぶ。
    func removeFollowRequests(answering request: MastodonNotification) {
        guard !isStopped, store.removeFollowRequests(answering: request) else { return }
        showEntries(animatesRemoval: true)
    }

    private func insertPending() {
        guard !isStopped else { return }
        #if DEBUG
        // 保留を解いたときに、releaseHeldArrivalsから挿入する。
        guard !DebugFaults.isHoldingArrivals else {
            logger.info("notifications insert pending held")
            return
        }
        #endif
        let added = store.flushPending()
        logger.info("notifications insert pending added=\(added.count, privacy: .public)")
        guard !added.isEmpty else { return }
        showEntries()
    }

    // MARK: - 既読位置

    /// 既読位置は未読を数える助けで、読めなくても通知は表示できるため、トークンの失効以外の失敗では位置なしで進める。
    private func loadMarker() async throws -> String? {
        do {
            return try await client.marker(for: .notifications)
        } catch let error as MastodonAPIError where error.isUnauthorized {
            throw error
        } catch is FeatureUnavailable {
            return nil
        } catch {
            logger.error("notifications marker load failed: \(SciaLog.describe(error), privacy: .public)")
            return nil
        }
    }

    private func syncReadPosition() {
        run(.automatic) { controller in
            do {
                guard let markerID = try await controller.client.marker(for: .notifications), !controller.isStopped else { return }
                controller.store.applySavedMarker(markerID)
                controller.updateUnreadCount()
            } catch {
                controller.handle(error, during: "marker sync") { _ in }
            }
        }
    }

    /// 既読位置が保存済みより進んでいれば保存する。保存している間に読み進めた分も、続けて保存する。
    private func saveReadPosition(inBackground: Bool) {
        guard !isStopped, store.readIDToSave != nil || isSavingReadPosition else { return }
        if inBackground, readPositionBackgroundTask == .invalid {
            readPositionBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "save notifications marker") { [weak self] in
                self?.endReadPositionBackgroundTask()
            }
        }
        guard !isSavingReadPosition else { return }
        isSavingReadPosition = true
        let client = client
        // 既読位置の保存は、スクロールやバックグラウンドへの移行で自動で送る。
        RequestOrigin.$current.withValue(.automatic) {
            Task { [weak self] in
                while let self, !self.isStopped, let id = self.store.readIDToSave {
                    do {
                        try await client.saveMarker(for: .notifications, lastReadID: id)
                        self.store.markSaved(id)
                        self.logger.info("notifications marker saved id=\(id, privacy: .public)")
                    } catch {
                        self.handle(error, during: "marker save") { _ in }
                        break
                    }
                }
                self?.isSavingReadPosition = false
                self?.endReadPositionBackgroundTask()
            }
        }
    }

    private func endReadPositionBackgroundTask() {
        guard readPositionBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(readPositionBackgroundTask)
        readPositionBackgroundTask = .invalid
    }

    /// 通知はタブを開いて見るだけのことが多いため、スクロールが止まるのを待たずに既読位置を保存する。
    /// スクロール中は止まったときに保存する。
    private func markRead(_ ids: [MastodonNotification.ID]) {
        store.markRead(ids)
        updateUnreadCount()
        if !viewController.isUserInteracting {
            saveReadPosition(inBackground: false)
        }
    }

    /// - Parameter animatesRemoval: 使う人の操作で行を消した。消える行を閉じる動きで消す。
    private func showEntries(animatesRemoval: Bool = false) {
        viewController.setEntries(store.entries, animatesRemoval: animatesRemoval)
        updateUnreadCount()
    }

    private func updateUnreadCount() {
        viewController.setUnreadCount(store.unreadCount, isLowerBound: store.hasUnloadedUnread)
        onUnreadCountChange?(store.unreadCount, store.hasUnloadedUnread)
    }

    private func handle(_ error: any Error, during operation: String, show: (ErrorPresentation) -> Void) {
        guard !isStopped, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        // 既読位置の保存など、このサーバーでは使えないと分かって止めた機能。止めたことは記録してあり、使う人に見せることもない。
        guard !(error is FeatureUnavailable) else { return }
        logger.error("notifications \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized()
        }
        show(ErrorPresentation(error))
    }
}
