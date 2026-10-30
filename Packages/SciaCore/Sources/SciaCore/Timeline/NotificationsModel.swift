public import Foundation
import os

/// 通知の読み込み、ストリーミング、既読位置、補完、新着の挿入の予約を受け持ち、結果を一覧の画面（`TimelineDisplay`）へ命令として伝える。
@MainActor
public final class NotificationsModel {
    /// 1回に読む件数。ホームと揃える。
    private static let pageSize = 40

    /// 結果を伝える一覧の画面。
    public weak var display: (any TimelineDisplay)?
    /// 一覧を最上部からさらに引っぱったときに見せる、ストリーミングの状態の表示。
    public weak var streamingStatus: (any StreamingStatusDisplay)?
    /// 未読の数が変わったときに呼ぶ。タブのバッジに出す。2つめの値は、実際はもっと多いかもしれないこと。
    public var onUnreadCountChange: ((Int, Bool) -> Void)?
    /// ストリーミングで新しい通知が届いたときに呼ぶ。ステータスバーに流す。2つめの値は、通知の投稿に当てたサーバーのフィルターの判定。
    public var onArrival: ((MastodonNotification, FilterVerdict) -> Void)?
    /// 通知の投稿に当てるサーバーのフィルター。ステータスバーに流す通知にも、一覧と同じく当てる。
    public let filtering: StatusFiltering
    private let store: NotificationStore
    private let client: MastodonClient
    private let streamingHub: StreamingHub
    private let tuning: TuningStore
    /// APIが401を返したときに呼ぶ。トークンが無効かを確かめ、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    /// バックグラウンドで既読位置を保存し終えるまで、アプリを止めないよう頼む。頼んで、終えるときに呼ぶものを返す。OSが与えた時間が尽きたら、頼みを終えて`onExpire`を呼ぶ。
    private let backgroundTime: @MainActor (String, _ onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void
    private let logger = SciaLog.logger(category: "notifications")
    /// この一覧が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときにも閉じる。
    private let tasks: TaskScope
    private var isStopped: Bool { tasks.isClosed }
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    public var runningTaskCount: Int { tasks.runningCount }
    /// 一覧全体の状態。失敗したままなら、電波の回復や引っぱった読み直しでやり直す。
    public private(set) var contentState = TimelineContentState.loaded
    /// 末尾の読み込みの状態。失敗したままなら、電波の回復でやり直す。
    public private(set) var footerState = TimelineFooterState.idle
    /// 設定で無効にしている。購読せず、有効に戻したらつなぎ直して、無効だった間を補う。
    private var isDisabled = false
    /// `user`ストリームの購読。読み込みが済んでから申し込み、止めるときやバックグラウンドではやめる。
    private var streamingSubscription: StreamingHub.Subscription?
    /// 切れていた間の通知を読む補完の状態。ストリーミングの状態と並べて、引っぱったときに見せる。
    private var catchUp = CatchUpStatus()
    /// ストリーミングで届いた通知の流れの速さ。引っぱったときに見せる。
    private var arrivalRate = ArrivalRate()
    private var hasLoadedInitial = false
    private var isInForeground = true
    private var isSavingReadPosition = false
    /// バックグラウンドで既読位置の保存を終えるまで、アプリを止めないよう頼んでいる。終えるときに呼ぶ。
    private var endReadPositionBackgroundTime: (@MainActor () -> Void)?
    private var isWaitingForInteractionToSettle = false
    #if DEBUG
    /// 新着の挿入を保留しているか。デバッグURL（`scia-debug://arrivals/hold`）で切り替える。
    public var isHoldingArrivals: @MainActor () -> Bool = { false }
    /// 新着の挿入を保留している間に、補完を見送った。保留を解いたときに補完する。
    private var isFillHeld = false
    #endif
    /// 走っている補完の数と、すべて終わるのを待っている引っぱった読み直し。
    private var activeFills = 0
    private var fillWaiters: [CheckedContinuation<Void, Never>] = []

    /// 新着をまとめて挿入する間隔を待つ時計。テストでは手で進める時計に替える。
    private let clock: any Clock<Duration>
    /// 補完を終えた日時と、通知の届いた日時に使う今の日付。
    private let now: () -> Date

    /// - Parameter backgroundTime: バックグラウンドで既読位置を保存し終えるまで、アプリを止めないよう頼む。頼んで、終えるときに呼ぶものを返す。OSが与えた時間が尽きたら、頼みを終えて`onExpire`を呼ぶ。
    public init(
        client: MastodonClient,
        streamingHub: StreamingHub,
        tuning: TuningStore,
        clock: any Clock<Duration>,
        now: @escaping () -> Date,
        backgroundTime: @escaping @MainActor (String, _ onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void,
        tasks: TaskScope,
        onUnauthorized: @escaping () -> Void
    ) {
        self.tasks = tasks
        self.clock = clock
        self.now = now
        let filtering = StatusFiltering(context: .notifications, myAccountID: client.credential.accountID)
        self.filtering = filtering
        store = NotificationStore(pageSize: Self.pageSize, filtering: filtering) { query in
            try await client.notifications(query)
        }
        self.client = client
        self.streamingHub = streamingHub
        self.tuning = tuning
        self.backgroundTime = backgroundTime
        self.onUnauthorized = onUnauthorized
        tasks.onClose { [weak self] in self?.stopStreaming() }
    }

    /// - Parameter purpose: 電波の回復などでやり直すときは`.display`。レート制限で止められている間は送らない。
    public func start(purpose: RequestPurpose = .action) {
        guard !isStopped else { return }
        hasStarted = true
        setContentState(.loading)
        run(purpose) { await $0.loadInitial() }
    }

    private var hasStarted = false

    /// まだ始めていなければ始める。無効にしていて起動のときに始めなかった通知を、有効にしたときに始めるのに使う。
    public func startIfNeeded() {
        guard !hasStarted else { return }
        start()
    }

    /// 設定で有効か無効かを切り替える。無効にしたら購読をやめ、有効に戻したら、読み込み済みならつなぎ直す。
    public func setEnabled(_ isEnabled: Bool) {
        guard isDisabled == isEnabled else { return }
        isDisabled = !isEnabled
        if isDisabled {
            stopStreaming()
        } else if hasLoadedInitial {
            startStreaming()
        }
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。セッションを閉じたときは、呼ばなくても持ち主が閉じて止まる。
    public func stop() {
        tasks.close()
    }

    /// バックグラウンドに入るときに呼ぶ。接続を切り、既読位置を保存する。
    public func enterBackground() {
        isInForeground = false
        stopStreaming()
        saveReadPosition(inBackground: true)
    }

    /// バックグラウンドから戻ったときに呼ぶ。つなぎ直して切れていた間の通知を補い、他の端末で読み進めた位置を取り込む。
    public func enterForeground() {
        isInForeground = true
        guard !isStopped else { return }
        // バックグラウンドにいる間に電波が戻ったり、レート制限が明けたりしても、その知らせでは読み込まない。戻ったここでやり直す。
        retryFailedLoads()
        guard hasLoadedInitial else { return }
        startStreaming()
        syncReadPosition()
    }

    /// - Parameter purpose: 自動の読み込みなら`.display`。レート制限で止められている間は送らずに失敗させる。
    @discardableResult
    private func run(_ purpose: RequestPurpose = .action, _ operation: @escaping @MainActor (NotificationsModel) async -> Void) -> Task<Void, Never>? {
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

    /// 一覧を引っぱって離したときに、最新の通知を読んで上に足す。足すのは一番新しい通知より新しいものだけで、読んでいる位置は動かさない。
    /// 最初の読み込みに失敗したままなら、それをやり直す。溜めている新着は、間隔を待たずに入れる。
    public func refresh() async {
        guard !isStopped, hasStarted, !isDisabled else { return }
        logger.info("notifications refresh")
        if !hasLoadedInitial {
            if case .failed = contentState {
                setContentState(.loading)
                await run { await $0.loadInitial() }?.value
            }
            return
        }
        // 補完の最中なら、ストアはその補完の後に続けて読む。続きを読み終えるまで閉じないよう、走っている補完もすべて待つ。
        fillFromLatest(purpose: .action)
        if activeFills > 0 {
            await withCheckedContinuation { fillWaiters.append($0) }
        }
        guard !isStopped else { return }
        insertPending()
    }

    private func endFill() {
        activeFills -= 1
        guard activeFills == 0 else { return }
        let waiters = fillWaiters
        fillWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// 失敗の表示の再試行が押されたときに呼ぶ。
    public func retry() {
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
            updateCatchUp { $0.finish(at: now()) }
            setContentState(.loaded)
            setFooterState(store.reachedEnd ? .reachedEnd : .idle)
            logger.info("notifications loadInitial done count=\(notifications.count, privacy: .public)")
            startStreaming()
        } catch {
            handle(error, during: "loadInitial") { setContentState(.failed($0)) }
        }
    }

    /// 末尾が近づいたときに呼ぶ。古い通知を自動で読む。
    public func approachEnd() {
        loadOlder(purpose: .display)
    }

    private func loadOlder(purpose: RequestPurpose = .action) {
        guard !isStopped, !store.isLoading, !store.reachedEnd, !store.isEmpty else { return }
        setFooterState(.loading)
        run(purpose) { model in
            do {
                guard let added = try await model.store.loadOlder(), !model.isStopped else { return }
                model.showEntries()
                model.setFooterState(model.store.reachedEnd ? .reachedEnd : .idle)
                model.logger.info("notifications loadOlder done added=\(added.count, privacy: .public)")
            } catch {
                model.handle(error, during: "loadOlder") { model.setFooterState(.failed($0)) }
            }
        }
    }

    /// 押したギャップを1ページ分読む。読んでいる側に続く行を基準にして、その位置を保つ。
    public func selectGap(_ id: String, from direction: TimelineStore.GapDirection) {
        guard !isStopped, !store.loadingGapIDs.contains(id) else { return }
        let entries = store.entries
        guard let index = entries.firstIndex(where: { $0.id == .gap(id) }) else { return }
        let neighborIndex = direction == .fromOlder ? entries.index(after: index) : entries.index(before: index)
        let anchorID = entries.indices.contains(neighborIndex) ? entries[neighborIndex].id : nil
        display?.setGapStates(loading: store.loadingGapIDs.union([id]), failures: store.gapFailures.filter { $0.key != id })
        run { model in
            do {
                let added = try await model.store.loadGap(id, from: direction)
                guard !model.isStopped else { return }
                model.showGapStates()
                guard let added else { return }
                model.display?.show(model.store.entries, keeping: anchorID)
                model.updateUnreadCount()
                model.logger.info("notifications loadGap done added=\(added.count, privacy: .public)")
            } catch {
                model.showGapStates()
                model.handle(error, during: "loadGap") { _ in }
            }
        }
    }

    private func showGapStates() {
        display?.setGapStates(loading: store.loadingGapIDs, failures: store.gapFailures)
    }

    // MARK: - ストリーミング

    private func startStreaming() {
        guard !isStopped, !isDisabled, isInForeground, streamingSubscription == nil else { return }
        streamingSubscription = streamingHub.subscribe(.user) { [weak self] activity in
            self?.streamingDidChange(activity)
        }
    }

    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。失敗したままの読み込みと、切れているストリーミングをすぐやり直す。
    public func recover() {
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
        if case .failed = contentState {
            start(purpose: .display)
        } else if case .failed = footerState {
            loadOlder(purpose: .display)
        }
    }

    /// ストリーミングの接続の状態を、引っぱったときに見せる表示へ伝える。
    public func showStreamingState(_ state: ConnectionDiagnostics.StreamingState?) {
        streamingStatus?.setState(state)
    }

    /// 補完で429や503を受けて止められていたら、待機中と出す。補完の終わりの反映を待たせないよう、別に確かめる。
    private func showPauseAfterFill() {
        let attempt = catchUp.attempt
        run(.display) { model in
            guard let until = await model.client.automaticRequestsPausedUntil() else { return }
            model.updateCatchUp { $0.pause(after: attempt, until: until) }
        }
    }

    private func updateCatchUp(_ change: (inout CatchUpStatus) -> Void) {
        change(&catchUp)
        streamingStatus?.setCatchUp(catchUp)
    }

    private func stopStreaming() {
        guard let streamingSubscription else { return }
        logger.info("notifications streaming unsubscribe")
        streamingSubscription.cancel()
        self.streamingSubscription = nil
        // 購読をやめた後は知らせが届かないので、出していた表示を消す。
        display?.setOutageNotice(false)
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
            display?.setOutageNotice(isOngoing)
        }
    }

    private func receive(_ notification: MastodonNotification) {
        arrivalRate.record(at: now())
        streamingStatus?.setArrivalRate(arrivalRate)
        // receiveの戻り値は、保留が空から1件になったかで、受け取ったかではない。挿入を待つ間に続けて届いた通知も流すよう、保留が増えたかで見る。
        let pendingCount = store.pending.count
        if store.receive(notification) {
            scheduleInsertion()
        }
        if store.pending.count > pendingCount {
            onArrival?(notification, notification.status.map { filtering.verdict(for: $0) } ?? .none)
        }
        // 挿入までに読み終えられるよう、届いたらすぐアイコンを読み始める。
        display?.prefetchAvatars(of: store.pending.map(TimelineEntry.notification))
    }

    #if DEBUG
    /// `scia-debug://inject/notifications`で読んだ通知を、ストリーミングで届いた通知と同じ経路で流す。サーバーにない通知なので、既読位置と補完の基準には使わない。
    public func inject(_ notifications: [MastodonNotification]) {
        guard !isStopped else { return }
        logger.info("debug inject notifications count=\(notifications.count, privacy: .public)")
        for notification in notifications {
            store.debugLocalOnlyIDs.insert(notification.id)
            receive(notification)
        }
    }
    #endif

    /// つながるたびと、つながらない間のポーリングで、切れていた間の通知を読む。
    private func fillFromLatest(purpose: RequestPurpose = .display) {
        #if DEBUG
        // 補完で読んだ新着はストアへ直接合流し、insertPendingの保留を通らないため、保留中は補完を始めない。
        // 保留を送る前に始まった補完は止めない。その結果は、保留中でも一覧に入る。
        if isHoldingArrivals() {
            isFillHeld = true
            logger.info("notifications fill held")
            return
        }
        #endif
        // 読み始める前に数える。走り始める前に引っぱった読み直しが待ち始めても、この補完を待つため。
        activeFills += 1
        run(purpose) { model in
            defer { model.endFill() }
            do {
                let before = model.store.entries
                let maxPages = Int(model.tuning.value(of: TuningCatalog.fillPageLimit))
                model.logger.info("notifications fill start")
                // 呼んだ時点ではなく読み始める直前に変える。呼んでから読み始めるまでに前の補完が終わると、その終わりで戻ってしまうため。
                // 補完の最中ならストアはnilを返し、今の補完が続けて読むので、その終わりで状態を戻す。
                model.updateCatchUp { $0.begin() }
                guard let added = try await model.store.fillFromLatest(maxPages: maxPages, progress: { count in
                    model.updateCatchUp { $0.progress(readCount: count) }
                }), !model.isStopped else { return }
                model.updateCatchUp { $0.finish(at: model.now()) }
                model.showPauseAfterFill()
                model.logger.info("notifications fill done added=\(added.count, privacy: .public)")
                // 待っている間に同じ通知がストリーミングで挿入されていても、ギャップを置いていることがある。
                // 読めなかった通知だけが増えたときも描き直すよう、表示する並びで比べる。
                guard model.store.entries != before else { return }
                model.showEntries()
                model.setFooterState(model.store.reachedEnd ? .reachedEnd : .idle)
            } catch {
                // 失敗しても、次につながったときに同じ基準から読み直す。
                model.updateCatchUp { $0.fail(error) }
                model.showPauseAfterFill()
                model.handle(error, during: "fill") { _ in }
            }
        }
    }

    /// 最初の通知が届いてから間隔をおいて、溜まった通知をまとめて挿入する。ホームと同じ間隔を使う。
    /// 挿入する前に、ホームと同じく、通知のアイコンが読み込み終わるのを上限まで待つ。
    private func scheduleInsertion() {
        let interval = tuning.value(of: TuningCatalog.insertionInterval)
        run { model in
            try? await model.clock.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            let wait = Duration.seconds(model.tuning.value(of: TuningCatalog.arrivalAvatarWait))
            await model.display?.waitForAvatars(of: { model.store.pending.map(TimelineEntry.notification) }, within: wait)
            guard !Task.isCancelled else { return }
            if model.display?.isUserInteracting == true {
                model.isWaitingForInteractionToSettle = true
            } else {
                model.insertPending()
            }
        }
    }

    #if DEBUG
    /// `scia-debug://arrivals/release`で保留を解いたとき、見送った補完を始め、溜まった新着を挿入する。指で操作している最中なら、操作が終わってから挿入する。
    public func releaseHeldArrivals() {
        if isFillHeld {
            isFillHeld = false
            fillFromLatest()
        }
        if display?.isUserInteracting == true {
            isWaitingForInteractionToSettle = true
        } else {
            insertPending()
        }
    }
    #endif

    /// 指によるスクロールが止まったとき、または長押しのメニューが閉じたときに呼ぶ。
    public func interactionDidSettle() {
        saveReadPosition(inBackground: false)
        guard isWaitingForInteractionToSettle else { return }
        isWaitingForInteractionToSettle = false
        insertPending()
    }

    /// 通知の対象の投稿の中身を変え、表示に関わる変化があれば描き直す。お気に入りなどの操作の結果を反映する。
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard !isStopped, store.updateStatus(id, transform) else { return }
        showEntries()
    }

    /// 削除した投稿についての通知を除く。
    public func removeStatus(_ id: Status.ID) {
        guard !isStopped, store.removeStatus(id) else { return }
        showEntries(animatesRemoval: true)
    }

    /// ミュートしたハッシュタグの付いた投稿の通知を除き、あとから届いても足さない。使う人の操作の結果なので、閉じる動きで消す。
    public func setTag(_ name: String, excluded: Bool) {
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
    public func setAccount(_ id: String, excluded: Bool) {
        guard !isStopped else { return }
        guard excluded else {
            store.includeAccount(id)
            return
        }
        guard store.excludeAccount(id) else { return }
        showEntries(animatesRemoval: true)
    }

    /// 使う人が削除した通知を除く。まとまりなら、キーでまとまりごと除く。
    public func removeNotification(_ notification: MastodonNotification) {
        guard !isStopped, store.removeNotification(notification.id, groupKey: notification.groupKey) else { return }
        showEntries(animatesRemoval: true)
    }

    /// 片づけたフォローリクエストの通知と、同じユーザーからのリクエストの通知を除く。承認か却下が済んだときに呼ぶ。
    public func removeFollowRequests(answering request: MastodonNotification) {
        guard !isStopped, store.removeFollowRequests(answering: request) else { return }
        showEntries(animatesRemoval: true)
    }

    private func insertPending() {
        guard !isStopped else { return }
        #if DEBUG
        // 保留を解いたときに、releaseHeldArrivalsから挿入する。
        guard !isHoldingArrivals() else {
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
        run(.display) { model in
            do {
                guard let markerID = try await model.client.marker(for: .notifications), !model.isStopped else { return }
                model.store.applySavedMarker(markerID)
                model.updateUnreadCount()
            } catch {
                model.handle(error, during: "marker sync") { _ in }
            }
        }
    }

    /// 既読位置が保存済みより進んでいれば保存する。保存している間に読み進めた分も、続けて保存する。
    private func saveReadPosition(inBackground: Bool) {
        guard !isStopped, store.readIDToSave != nil || isSavingReadPosition else { return }
        if inBackground, endReadPositionBackgroundTime == nil {
            endReadPositionBackgroundTime = backgroundTime("save notifications marker") { [weak self] in
                // 尽きたら、次にバックグラウンドへ入ったときに頼み直す。
                self?.endReadPositionBackgroundTask()
            }
        }
        guard !isSavingReadPosition else { return }
        isSavingReadPosition = true
        let client = client
        // 既読位置の保存は、スクロールやバックグラウンドへの移行で自動で送る。
        RequestPurpose.$current.withValue(.display) {
            tasks.run { [weak self] in
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
        guard let end = endReadPositionBackgroundTime else { return }
        endReadPositionBackgroundTime = nil
        end()
    }

    /// 画面に表示されている通知が変わったときに呼ぶ。
    /// 通知はタブを開いて見るだけのことが多いため、スクロールが止まるのを待たずに既読位置を保存する。
    /// スクロール中は止まったときに保存する。
    public func markRead(_ ids: [MastodonNotification.ID]) {
        store.markRead(ids)
        updateUnreadCount()
        if display?.isUserInteracting != true {
            saveReadPosition(inBackground: false)
        }
    }

    /// - Parameter animatesRemoval: 使う人の操作で行を消した。消える行を閉じる動きで消す。
    private func showEntries(animatesRemoval: Bool = false) {
        showGapStates()
        display?.show(store.entries, animatesRemoval: animatesRemoval)
        updateUnreadCount()
    }

    private func updateUnreadCount() {
        display?.setUnreadCount(store.unreadCount, isLowerBound: store.hasUnloadedUnread)
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
