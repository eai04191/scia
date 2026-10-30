public import Foundation
import os

/// ホームや公開タイムラインの読み込み、ストリーミング、既読位置、ポーリング、補完、新着の挿入の予約を受け持ち、結果を一覧の画面（`TimelineDisplay`）へ命令として伝える。
/// タブの一覧のほか、開いた一覧に積むハッシュタグの一覧にも使う。
@MainActor
public final class FeedTimelineModel {
    /// 1回に読む件数。APIの上限が40件。
    public static let pageSize = 40

    public let feed: TimelineFeed
    /// この一覧で当てるサーバーのフィルター。画面の警告の折りたたみにも同じものを使う。
    public let filtering: StatusFiltering
    /// 結果を伝える一覧の画面。
    public weak var display: (any TimelineDisplay)?
    /// 一覧を最上部からさらに引っぱったときに見せる、ストリーミングの状態の表示。
    public weak var streamingStatus: (any StreamingStatusDisplay)?
    private let store: TimelineStore
    private let client: MastodonClient
    private let streamingHub: StreamingHub
    private let tuning: TuningStore
    /// APIが401を返したときに呼ぶ。トークンが無効かを確かめ、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    /// バックグラウンドで既読位置を保存し終えるまで、アプリを止めないよう頼む。頼んで、終えるときに呼ぶものを返す。OSが与えた時間が尽きたら、頼みを終えて`onExpire`を呼ぶ。
    private let backgroundTime: @MainActor (String, _ onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void
    private let logger = SciaLog.logger(category: "timeline")
    /// この一覧が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときにも閉じる。
    private let tasks: TaskScope
    /// 走り終えていない読み込みなどの処理の数。止めたものも、取り消しを受けて戻り切るまで数える。止めたあとに何も起きないことを、テストが確かめるのに使う。
    public var runningTaskCount: Int { tasks.runningCount }
    /// 新着をまとめて挿入する間隔、ポーリング、作り直しの読み直しを待つ時計。テストでは手で進める時計に替える。
    public let clock: any Clock<Duration>
    /// 補完を終えた日時、新着の届いた日時、ダミーの投稿の日時に使う今の日付。テストでは決まった日付に替える。
    public let now: () -> Date
    public var isStopped: Bool { tasks.isClosed }
    /// 一覧全体の状態。失敗したままなら、電波の回復や引っぱった読み直しでやり直す。
    public private(set) var contentState = TimelineContentState.loaded
    /// 末尾の読み込みの状態。失敗したままなら、電波の回復でやり直す。
    public private(set) var footerState = TimelineFooterState.idle
    /// 設定で無効にしている。購読せず、有効に戻したらつなぎ直して、無効だった間を補う。
    private var isDisabled = false
    private var hasStarted = false
    /// 一覧のストリームの購読。読み込みが済んでから申し込み、止めるときやバックグラウンドではやめる。
    private var streamingSubscription: StreamingHub.Subscription?
    /// 一覧のストリームを購読している。
    public var isSubscribedToStreaming: Bool { streamingSubscription != nil }
    /// 切れていた間の投稿を読む補完の状態。ストリーミングの状態と並べて、引っぱったときに見せる。
    private var catchUp = CatchUpStatus()
    /// ストリーミングで届いた新着の流れの速さ。引っぱったときに見せる。
    private var arrivalRate = ArrivalRate()
    /// 最初の読み込みが済んだ。空のホームでも、済んでいればつなぐ。
    private var hasLoadedInitial = false
    /// バックグラウンドでは接続しない。最初の読み込みの途中でバックグラウンドへ入っても、読み込み後につながないようにする。
    private var isInForeground = true
    /// 近づいたときの自動の読み込みに失敗した、または進まなかったギャップ。読み直し続けないよう、タップされるまで自動では読まない。
    private var autoLoadFailedGapIDs: Set<String> = []
    private var isSavingReadPosition = false
    /// バックグラウンドで既読位置の保存を終えるまで、アプリを止めないよう頼んでいる。終えるときに呼ぶ。
    private var endReadPositionBackgroundTime: (@MainActor () -> Void)?
    /// 新着を挿入するタイミングが来たが、スクロールや長押しのメニューなどの操作中なので、終わるのを待っている。
    private var isWaitingForInteractionToSettle = false
    #if DEBUG
    /// 新着の挿入を保留しているか。デバッグURL（`scia-debug://arrivals/hold`）で切り替える。
    public var isHoldingArrivals: @MainActor () -> Bool = { false }
    /// 新着の挿入を保留している間に、補完を見送った。保留を解いたときに補完する。
    private var isFillHeld = false
    #endif
    /// サーバーがホームを作り直している最中だったので、時間をおいて補完を読み直す。読み直すまで次は予約しない。
    private var regeneratingRetryTask: Task<Void, Never>?
    /// 画面が前に出ている。ストリームでは足りない一覧は、前に出ている間だけ新着を読み直す。
    private var isShown = false
    /// 前に出ている間に新着を読み直す繰り返し。
    private var pollingTask: Task<Void, Never>?
    /// 走っている補完の数と、すべて終わるのを待っている引っぱった読み直し。
    private var activeFills = 0
    private var fillWaiters: [CheckedContinuation<Void, Never>] = []
    /// 走っている補完が終わるのを待っている、引っぱった読み直しの数。テストで、待ち始めたことを時間を待たずに確かめる。
    public var fillWaiterCount: Int { fillWaiters.count }

    /// - Parameter backgroundTime: バックグラウンドで既読位置を保存し終えるまで、アプリを止めないよう頼む。頼んで、終えるときに呼ぶものを返す。OSが与えた時間が尽きたら、頼みを終えて`onExpire`を呼ぶ。
    public init(
        feed: TimelineFeed,
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
        let filtering = StatusFiltering(context: feed.filterContext, myAccountID: client.credential.accountID)
        self.filtering = filtering
        store = TimelineStore(pageSize: Self.pageSize, filtering: filtering) { query in
            try await feed.page(query, from: client)
        }
        self.feed = feed
        self.client = client
        self.streamingHub = streamingHub
        self.tuning = tuning
        self.backgroundTime = backgroundTime
        self.onUnauthorized = onUnauthorized
        tasks.onClose { [weak self] in self?.didStop() }
    }

    /// - Parameter purpose: 電波の回復などでやり直すときは`.display`。レート制限で止められている間は送らない。
    public func start(purpose: RequestPurpose = .action) {
        guard !isStopped else { return }
        hasStarted = true
        setContentState(.loading)
        run(purpose) { await $0.loadInitial() }
    }

    /// まだ始めていなければ始める。開くまで読まない一覧を、初めて開いたときに始めるのに使う。
    public func startIfNeeded() {
        guard !hasStarted else { return }
        start()
    }

    #if DEBUG
    /// 始めている一覧だけ読み込み直す。障害を起こすデバッグURLで、開いたことのない一覧まで読み始めないようにする。
    public func reloadIfStarted() {
        guard hasStarted else { return }
        start()
    }
    #endif

    /// 設定で有効か無効かを切り替える。無効にしたら購読をやめ、有効に戻したら、読み込み済みならつなぎ直す。
    public func setEnabled(_ isEnabled: Bool) {
        guard isDisabled == isEnabled else { return }
        isDisabled = !isEnabled
        if isDisabled {
            stopStreaming()
            // 作り直し中の読み直しも、使わない一覧への通信なのでやめる。有効に戻したら、つないだところで補完する。
            cancelRegeneratingRetry()
            stopPolling()
        } else if hasLoadedInitial {
            startStreaming()
            startPolling()
        }
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときと、積んで開いた一覧がナビゲーションから外されたときに呼ぶ。
    /// セッションを閉じたときは、呼ばなくても持ち主が閉じて止まる。
    public func stop() {
        tasks.close()
    }

    /// 持ち主が閉じたときに呼ぶ。走っている処理は持ち主が取り消すので、ここではTaskでないものを止める。
    private func didStop() {
        stopStreaming()
        regeneratingRetryTask = nil
        pollingTask = nil
    }

    /// バックグラウンドに入るときに呼ぶ。バックグラウンドでは接続が止められるため自分から切り、既読位置を保存する。
    public func enterBackground() {
        isInForeground = false
        stopStreaming()
        // 戻ったときは、つなぎ直したところで補完する。
        cancelRegeneratingRetry()
        stopPolling()
        saveReadPosition(inBackground: true)
    }

    /// バックグラウンドから戻ったときに呼ぶ。つなぎ直して切れていた間の投稿を補い、他の端末で読み進めた位置を取り込む。
    /// 最初の読み込みが済んでいなければ、済んだ時点でつなぐので何もしない。
    public func enterForeground() {
        isInForeground = true
        guard !isStopped else { return }
        // バックグラウンドにいる間に電波が戻ったり、レート制限が明けたりしても、その知らせでは読み込まない。戻ったここでやり直す。
        retryFailedLoads()
        guard hasLoadedInitial else { return }
        startStreaming()
        // ストリームにつながらない環境でも、見ている一覧はすぐ読む。つながったときの補完と重なれば、ストアが1つにまとめる。
        if feed.isAccountHashtag, isShown, !isDisabled {
            fillFromLatest()
        }
        startPolling()
        syncReadPosition()
    }

    // MARK: - 前に出ている間の読み直し

    /// 画面が前に出たら、見ていなかった間の新着を読み、前に出ている間は間隔をおいて読み直す。見えなくなったらやめる。
    /// ユーザーのハッシュタグの一覧で使う。ハッシュタグのストリームは公開の投稿しか運ばず、フォロワーのみなどの投稿は読まないと分からないため。
    /// 見ていない間は読まず、通信を前に出ている1つの一覧の分に抑える。決まりはdocs/tabs.mdの「ユーザーのハッシュタグ」にある。
    public func setShown(_ isShown: Bool) {
        guard self.isShown != isShown else { return }
        self.isShown = isShown
        guard isShown else {
            stopPolling()
            return
        }
        if !isStopped, !isDisabled, isInForeground {
            // 見ていない間に見送った、失敗した読み込みのやり直し。
            retryFailedLoads()
            if hasLoadedInitial {
                fillFromLatest()
            }
        }
        startPolling()
    }

    /// ストリームから来る補完のきっかけ（つながったとき、切れている間のポーリング、届いた投稿）で読む。
    /// ユーザーのハッシュタグは、見ていない間は読まない。見えたときに`setShown`で読むので、見ていない間の新着は取りこぼさない。
    private func fillFromLatestIfShownWhenNeeded() {
        guard !feed.isAccountHashtag || isShown else { return }
        fillFromLatest()
    }

    private func startPolling() {
        guard isShown, !isStopped, !isDisabled, isInForeground, pollingTask == nil else { return }
        pollingTask = tasks.run { [weak self, clock] in
            while let interval = self?.tuning.value(of: TuningCatalog.accountHashtagPollingInterval) {
                try? await clock.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard self.hasLoadedInitial else { continue }
                self.logger.info("\(self.feed.name, privacy: .public) poll while shown")
                self.fillFromLatest()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。失敗したままの読み込みと、切れているストリーミングをすぐやり直す。
    public func recover() {
        guard !isStopped, isInForeground else { return }
        autoLoadFailedGapIDs.removeAll()
        // 切れていれば、セッションがつなぎ直させ、つながったところで切れていた間を補う。
        if hasLoadedInitial, !isDisabled, streamingHub.isConnected {
            // つながったときの補完が、止められている間や電波のない間に失敗していることがある。
            fillFromLatestIfShownWhenNeeded()
        }
        retryFailedLoads()
    }

    /// 失敗したままの最初の読み込みか、末尾の読み込みをやり直す。最初の読み込みが済めば、そこでつなぐ。
    /// ユーザーのハッシュタグは、見ていない間は読まない。見えたときに`setShown`でやり直す。
    private func retryFailedLoads() {
        guard !feed.isAccountHashtag || isShown else { return }
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
        logger.info("\(self.feed.name, privacy: .public) streaming unsubscribe")
        streamingSubscription.cancel()
        self.streamingSubscription = nil
        // 購読をやめた後は知らせが届かないので、出していた表示を消す。
        display?.setOutageNotice(false)
    }

    private func setContentState(_ state: TimelineContentState) {
        contentState = state
        display?.setContentState(state)
    }

    private func setFooterState(_ state: TimelineFooterState) {
        footerState = state
        display?.setFooterState(state)
    }

    /// - Parameter purpose: 自動の読み込みなら`.display`。レート制限で止められている間は送らずに失敗させる。
    @discardableResult
    private func run(_ purpose: RequestPurpose = .action, _ operation: @escaping @MainActor (FeedTimelineModel) async -> Void) -> Task<Void, Never>? {
        // 作ったTaskは、作ったときのtask-localの値を引き継ぐ。
        RequestPurpose.$current.withValue(purpose) {
            tasks.run { [weak self] in
                guard let self else { return }
                await operation(self)
            }
        }
    }

    /// 一覧を引っぱって離したときに、最新の投稿を読んで上に足す。足すのは一番新しい投稿より新しいものだけで、読んでいる位置は動かさない。
    /// 最初の読み込みに失敗したままなら、それをやり直す。溜めている新着は、間隔を待たずに入れる。
    public func refresh() async {
        guard !isStopped, hasStarted, !isDisabled else { return }
        logger.info("\(self.feed.name, privacy: .public) refresh")
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

    /// 失敗の表示の再試行が押されたときに呼ぶ。
    public func retry() {
        if store.isEmpty {
            start()
        } else {
            loadOlder()
        }
    }

    private func loadInitial() async {
        logger.info("\(self.feed.name, privacy: .public) loadInitial start")
        do {
            let markerID = try await loadMarker()
            guard let statuses = try await store.loadInitial(around: markerID), !isStopped else { return }
            // 前回読んだところから続きを読めるよう、既読位置の投稿を最上部に置く。新しい投稿はその上にある。
            let topID = markerID.flatMap { id in store.statuses.contains { $0.id == id } ? TimelineEntry.ID.status(id) : nil }
            display?.show(store.entries, placingAtTop: topID)
            updateUnreadCount()
            hasLoadedInitial = true
            updateCatchUp { $0.finish(at: now(), isRegenerating: store.isRegenerating) }
            setContentState(store.isEmpty && store.isRegenerating ? .regenerating : .loaded)
            setFooterState(store.reachedEnd ? .reachedEnd : .idle)
            logger.info("\(self.feed.name, privacy: .public) loadInitial done count=\(statuses.count, privacy: .public) regenerating=\(self.store.isRegenerating, privacy: .public)")
            startStreaming()
        } catch {
            handle(error, during: "loadInitial") { setContentState(.failed($0)) }
        }
    }

    /// 末尾が近づいたときに呼ぶ。古い投稿を自動で読む。
    public func approachEnd() {
        loadOlder(purpose: .display)
    }

    private func loadOlder(purpose: RequestPurpose = .action) {
        guard !isStopped, !store.isLoading, !store.reachedEnd, !store.isEmpty else { return }
        setFooterState(.loading)
        run(purpose) { model in
            model.logger.info("\(model.feed.name, privacy: .public) loadOlder start")
            do {
                guard let added = try await model.store.loadOlder(), !model.isStopped else { return }
                model.display?.show(model.store.entries)
                // 並べ直すとフィルターの期限が切れた投稿が戻り、未読の数が変わることがある。既読の報告は位置が進まないと数え直さない。
                model.updateUnreadCount()
                model.setFooterState(model.store.reachedEnd ? .reachedEnd : .idle)
                model.logger.info("\(model.feed.name, privacy: .public) loadOlder done added=\(added.count, privacy: .public) reachedEnd=\(model.store.reachedEnd, privacy: .public)")
            } catch {
                model.handle(error, during: "loadOlder") { model.setFooterState(.failed($0)) }
            }
        }
    }

    // MARK: - ストリーミング

    private func startStreaming() {
        guard !isStopped, !isDisabled, isInForeground, streamingSubscription == nil else { return }
        streamingSubscription = streamingHub.subscribe(feed.subscription) { [weak self] activity in
            self?.streamingDidChange(activity)
        }
    }

    private func streamingDidChange(_ activity: StreamingHub.Activity) {
        guard !isStopped else { return }
        switch activity {
        case .connected:
            logger.info("\(self.feed.name, privacy: .public) streaming connected")
            fillFromLatestIfShownWhenNeeded()
        case .event(let event):
            receive(event)
        case .poll:
            logger.info("\(self.feed.name, privacy: .public) poll")
            fillFromLatestIfShownWhenNeeded()
        case .outage(let isOngoing):
            display?.setOutageNotice(isOngoing)
        }
    }

    /// つながるたびと、つながらない間のポーリングで、切れていた間の投稿を読む。1ページに収まらなければギャップを置く。
    private func fillFromLatest(purpose: RequestPurpose = .display) {
        #if DEBUG
        // 補完で読んだ新着はストアへ直接合流し、insertPendingの保留を通らないため、保留中は補完を始めない。
        // 保留を送る前に始まった補完は止めない。その結果は、保留中でも一覧に入る。
        if isHoldingArrivals() {
            isFillHeld = true
            logger.info("\(self.feed.name, privacy: .public) fill held")
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
                model.logger.info("\(model.feed.name, privacy: .public) fill start")
                // 呼んだ時点ではなく読み始める直前に変える。呼んでから読み始めるまでに前の補完が終わると、その終わりで戻ってしまうため。
                // 補完の最中ならストアはnilを返し、今の補完が続けて読むので、その終わりで状態を戻す。
                model.updateCatchUp { $0.begin() }
                guard let added = try await model.store.fillFromLatest(maxPages: maxPages, progress: { count in
                    model.updateCatchUp { $0.progress(readCount: count) }
                }), !model.isStopped else { return }
                // 作り直し中かは、下の読み直しの予約と同じくストアの直近の読み込みで見る。補完が206を受けて残りを読んでいる間に、
                // 末尾の読み込みが200で終わると、補完の結果は揃っていないのに作り直し中でないことになり、読み直しを予約せず、時刻も進む。
                // 起きるのは、作り直し中に補完と末尾の読み込みが重なったときだけ。補完ごとの結果を返すようストアを変える必要があり、この表示の範囲を超えるので直していない。
                // 表示を予約と食い違わせないよう、同じ値を使う。
                model.updateCatchUp { $0.finish(at: model.now(), isRegenerating: model.store.isRegenerating) }
                model.showPauseAfterFill()
                model.logger.info("\(model.feed.name, privacy: .public) fill done added=\(added.count, privacy: .public) gaps=\(model.store.gaps.count, privacy: .public) regenerating=\(model.store.isRegenerating, privacy: .public)")
                if model.store.isRegenerating {
                    model.scheduleRegeneratingRetry()
                }
                // 待っている間に同じ投稿がストリーミングで挿入されていても、ギャップだけが増えていることがある。
                guard model.store.entries != before else { return }
                model.showEntries()
                if before.isEmpty {
                    // 空のホームへ最新のページを読んだ。その先に古い投稿が残っているかもしれない。
                    model.setFooterState(model.store.reachedEnd ? .reachedEnd : .idle)
                }
            } catch {
                // 失敗しても、次につながったときに同じ基準から読み直す。
                model.updateCatchUp { $0.fail(error) }
                model.showPauseAfterFill()
                model.handle(error, during: "fill") { _ in }
                // 作り直し中の読み直しが失敗したら、つながったままでは次のきっかけが来ないので、読み直しを続ける。
                if model.store.isRegenerating {
                    model.scheduleRegeneratingRetry()
                }
            }
        }
    }

    private func endFill() {
        activeFills -= 1
        guard activeFills == 0 else { return }
        let waiters = fillWaiters
        fillWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// サーバーがホームを作り直している最中で結果が揃っていなかったので、時間をおいて補完を読み直す。
    /// つながりが安定していると、次に補完するきっかけが来ず、作り直しの後に揃った投稿が届かないため。
    private func scheduleRegeneratingRetry() {
        guard regeneratingRetryTask == nil, !isStopped, !isDisabled, isInForeground else { return }
        let interval = tuning.value(of: TuningCatalog.regeneratingRetryInterval)
        logger.info("\(self.feed.name, privacy: .public) regenerating retry scheduled after=\(interval, privacy: .public)")
        regeneratingRetryTask = tasks.run { [weak self, clock] in
            try? await clock.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            regeneratingRetryTask = nil
            guard !isStopped, !isDisabled, isInForeground else { return }
            fillFromLatest()
        }
    }

    private func cancelRegeneratingRetry() {
        regeneratingRetryTask?.cancel()
        regeneratingRetryTask = nil
    }

    /// ギャップがタップされたときに呼ぶ。失敗して自動では読まなくなったギャップも読む。
    public func selectGap(_ id: String, from direction: TimelineStore.GapDirection) {
        loadGap(id, from: direction, isAutomatic: false)
    }

    /// 読み込み中でないギャップが表示領域に近づいたときに呼ぶ。スクロールするたびに呼ばれることがある。
    public func approachGap(_ id: String, from direction: TimelineStore.GapDirection) {
        loadGap(id, from: direction, isAutomatic: true)
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
        display?.setGapStates(loading: store.loadingGapIDs.union([id]), failures: store.gapFailures.filter { $0.key != id })
        let gapBefore = store.gaps.first { $0.id == id }
        run(isAutomatic ? .display : .action) { model in
            model.logger.info("\(model.feed.name, privacy: .public) loadGap start id=\(id, privacy: .public) direction=\(String(describing: direction), privacy: .public) automatic=\(isAutomatic, privacy: .public)")
            do {
                let added = try await model.store.loadGap(id, from: direction)
                guard !model.isStopped else { return }
                // 再生成中の空の結果などでギャップが縮まなければ、描き直しの後にすぐ同じギャップを読み直してしまうため、
                // 失敗と同じくタップされるまで自動では読まない。
                if isAutomatic, added?.isEmpty == true, model.store.gaps.contains(where: { $0 == gapBefore }) {
                    model.autoLoadFailedGapIDs.insert(id)
                }
                model.showGapStates()
                guard let added else { return }
                model.display?.show(model.store.entries, keeping: anchorID)
                model.updateUnreadCount()
                model.logger.info("\(model.feed.name, privacy: .public) loadGap done added=\(added.count, privacy: .public)")
            } catch {
                if isAutomatic {
                    model.autoLoadFailedGapIDs.insert(id)
                }
                model.showGapStates()
                model.handle(error, during: "loadGap") { _ in }
            }
        }
    }

    /// 投稿の応答で返った自分の投稿を、ストリーミングで届くのを待たずに新着と同じ経路で流す。
    public func receivePosted(_ status: Status) {
        guard !isStopped else { return }
        logger.info("\(self.feed.name, privacy: .public) posted status=\(status.id, privacy: .public)")
        apply(store.receivePosted(status))
    }

    private func receive(_ event: StreamingEvent) {
        guard !isStopped else { return }
        if case .update(let status) = event {
            switch feed.handling(ofStreamed: status) {
            case .insert: break
            case .ignore: return
            case .fetchLatest:
                fillFromLatestIfShownWhenNeeded()
                return
            }
        }
        if case .update = event {
            arrivalRate.record(at: now())
            streamingStatus?.setArrivalRate(arrivalRate)
        }
        apply(store.receive(event))
    }

    private func apply(_ result: TimelineStore.EventResult) {
        switch result {
        case .none:
            break
        case .pendingStarted:
            scheduleInsertion()
        case .entriesChanged:
            showEntries()
        }
        // 挿入までに読み終えられるよう、届いたらすぐアイコンを読み始める。
        display?.prefetchAvatars(of: store.pending.map(TimelineEntry.status))
    }

    /// 最初の新着が届いてから間隔をおいて、溜まった新着をまとめて挿入する。
    /// 挿入する前に、新着のアイコンが読み込み終わるのを上限まで待ち、行が出た時点でアイコンを描けているようにする。
    private func scheduleInsertion() {
        let interval = tuning.value(of: TuningCatalog.insertionInterval)
        run { model in
            try? await model.clock.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            let wait = Duration.seconds(model.tuning.value(of: TuningCatalog.arrivalAvatarWait))
            await model.display?.waitForAvatars(of: { model.store.pending.map(TimelineEntry.status) }, within: wait)
            guard !Task.isCancelled else { return }
            if model.display?.isUserInteracting == true {
                // 指の動きと関係なく画面が動かないよう、スクロールや長押しのメニューなどの操作が終わってから挿入する。
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

    // MARK: - 既読位置

    /// 既読位置はタイムラインを読む助けで、読めなくてもタイムラインは表示できるため、トークンの失効以外の失敗では位置なしで進める。
    private func loadMarker() async throws -> String? {
        guard let marker = feed.marker else { return nil }
        do {
            return try await client.marker(for: marker)
        } catch let error as MastodonAPIError where error.isUnauthorized {
            throw error
        } catch is FeatureUnavailable {
            return nil
        } catch {
            logger.error("\(self.feed.name, privacy: .public) marker load failed: \(SciaLog.describe(error), privacy: .public)")
            return nil
        }
    }

    private func syncReadPosition() {
        guard let marker = feed.marker else { return }
        run(.display) { model in
            do {
                guard let markerID = try await model.client.marker(for: marker), !model.isStopped else { return }
                model.store.applySavedMarker(markerID)
                model.updateUnreadCount()
                model.logger.info("\(model.feed.name, privacy: .public) marker synced id=\(markerID, privacy: .public)")
            } catch {
                model.handle(error, during: "marker sync") { _ in }
            }
        }
    }

    /// 既読位置が保存済みより進んでいれば保存する。保存している間に読み進めた分も、続けて保存する。
    /// 競合などで失敗したら、次にスクロールが止まったときに保存し直す。
    private func saveReadPosition(inBackground: Bool) {
        guard !isStopped, let marker = feed.marker, store.readIDToSave != nil || isSavingReadPosition else { return }
        if inBackground, endReadPositionBackgroundTime == nil {
            // バックグラウンドに入るときは、保存し終えるまでアプリを止めないよう頼んでおく。保存中の分も含める。
            endReadPositionBackgroundTime = backgroundTime("save \(marker.rawValue) marker") { [weak self] in
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
                        try await client.saveMarker(for: marker, lastReadID: id)
                        self.store.markSaved(id)
                        self.logger.info("\(self.feed.name, privacy: .public) marker saved id=\(id, privacy: .public)")
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

    /// 投稿とそれをブーストした投稿の中身を変え、表示に関わる変化があれば描き直す。お気に入りなどの操作の結果を反映する。
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard !isStopped, store.updateStatus(id, transform) else { return }
        showEntries()
    }

    /// 削除した投稿と、それをブーストした投稿を除く。ストリーミングの削除の知らせを待たずに消す。
    /// 消える行は閉じる動きで消す。ストリーミングの削除の知らせがRESTの応答より先に届くと、そちらで動かさずに消え、ここでは何もしない。
    /// Mastodonは削除の知らせを応答の後に別のジョブで配るので、まれな競合として、削除中の投稿を覚えて知らせを見分ける仕組みは足さない。
    public func removeStatus(_ id: Status.ID) {
        guard !isStopped, store.removeStatus(id) else { return }
        showEntries(animatesRemoval: true)
    }

    /// ミュートしたハッシュタグの付いた投稿とブーストを除き、あとから届いても足さない。使う人の操作の結果なので、閉じる動きで消す。
    public func setTag(_ name: String, excluded: Bool) {
        guard !isStopped else { return }
        guard excluded else {
            store.includeTag(name)
            return
        }
        guard store.excludeTag(name) else { return }
        showEntries(animatesRemoval: true)
    }

    /// ミュートかブロックした相手の投稿とブーストを除き、あとから届いても足さない。使う人の操作の結果なので、閉じる動きで消す。
    /// 解除したら、また足すようにする。除いた投稿は、読み込み直すまで戻さない。
    public func setAccount(_ id: String, excluded: Bool) {
        guard !isStopped else { return }
        guard excluded else {
            store.includeAccount(id)
            return
        }
        guard store.excludeAccount(id) else { return }
        showEntries(animatesRemoval: true)
    }

    private func insertPending() {
        guard !isStopped else { return }
        #if DEBUG
        // 保留を解いたときに、releaseHeldArrivalsから挿入する。
        guard !isHoldingArrivals() else {
            logger.info("\(self.feed.name, privacy: .public) insert pending held")
            return
        }
        #endif
        let before = store.entries
        let added = store.flushPending()
        logger.info("\(self.feed.name, privacy: .public) insert pending added=\(added.count, privacy: .public)")
        // フィルターで隠す投稿は足さないが、同じIDの読めなかった行は消えるため、並びの変化で見る。
        guard store.entries != before else { return }
        // 挿入は行を足すか除くだけで、残る行の中身は変えない。
        showEntries(keepingRowContentsOf: before)
    }

    /// 自動の補完の中でギャップを読めなかったときも、並びと一緒に読めなかった表示にする。
    /// - Parameter animatesRemoval: 使う人の操作で行を消した。消える行を閉じる動きで消す。
    /// - Parameter base: 一覧はこの並びに行を足すか除くかしただけで、残る行の中身を変えていない。
    private func showEntries(animatesRemoval: Bool = false, keepingRowContentsOf base: [TimelineEntry]? = nil) {
        showGapStates()
        display?.show(store.entries, animatesRemoval: animatesRemoval, keepingRowContentsOf: base)
        updateUnreadCount()
    }

    private func showGapStates() {
        display?.setGapStates(loading: store.loadingGapIDs, failures: store.gapFailures)
    }

    /// 画面に表示されている投稿が変わったときに呼ぶ。スクロールの毎コマで呼ばれるため、既読の位置が進んだときだけ未読を数え直す。
    public func markRead(_ ids: [Status.ID]) {
        guard store.markRead(ids) else { return }
        updateUnreadCount()
    }

    private func updateUnreadCount() {
        display?.setUnreadCount(store.unreadCount, isLowerBound: store.hasUnloadedUnread)
    }

    private func handle(_ error: any Error, during operation: String, show: (ErrorPresentation) -> Void) {
        // 止めた後に届いた結果や、止めたことによる取り消しは、もう画面に関係しない。
        guard !isStopped, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        // 既読位置の保存など、このサーバーでは使えないと分かって止めた機能。止めたことは記録してあり、使う人に見せることもない。
        guard !(error is FeatureUnavailable) else { return }
        logger.error("\(self.feed.name, privacy: .public) \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized()
        }
        show(ErrorPresentation(error))
    }
}

#if DEBUG
// MARK: - 検証用

extension FeedTimelineModel {
    /// 検証用の投稿を作るのに、読み込んだ投稿やストアの検証用の操作を使う。
    public var debugStore: TimelineStore { store }

    /// ストリーミングで届いたのと同じ経路で流す。
    public func debugReceive(_ event: StreamingEvent) {
        receive(event)
    }

    /// この一覧の処理の持ち主の中で、使う人の操作として走らせる。
    @discardableResult
    public func debugRun(_ operation: @escaping @MainActor (FeedTimelineModel) async -> Void) -> Task<Void, Never>? {
        run(.action, operation)
    }

    /// 検証用の操作の失敗を、ほかの読み込みの失敗と同じく記録する。
    public func debugReport(_ error: any Error, during operation: String) {
        handle(error, during: operation) { _ in }
    }

    /// 最新の投稿を`count`件忘れてからつなぎ直し、実データで補完とギャップを起こす。
    public func debugForgetNewestAndReconnect(_ count: Int) {
        logger.info("debug forget newest count=\(count, privacy: .public)")
        stopStreaming()
        store.debugForgetNewest(count)
        showEntries()
        startStreaming()
    }
}
#endif
