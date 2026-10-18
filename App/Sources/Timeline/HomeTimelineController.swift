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
    private let streamingHub: StreamingHub
    private let tuning: TuningStore
    /// APIが401を返したときに呼ぶ。トークンが無効かを確かめ、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "timeline")
    private var tasks: [Task<Void, Never>] = []
    private var isStopped = false
    /// `user`ストリームの購読。読み込みが済んでから申し込み、止めるときやバックグラウンドではやめる。
    private var streamingSubscription: StreamingHub.Subscription?
    /// 一覧を最上部からさらに引っぱったときに見せる、ストリーミングの状態。
    private let streamingStatusView = StreamingStatusPullView()
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
    #if DEBUG
    /// 新着の挿入を保留している間に、補完を見送った。保留を解いたときに補完する。
    private var isFillHeld = false
    #endif
    /// サーバーがホームを作り直している最中だったので、時間をおいて補完を読み直す。読み直すまで次は予約しない。
    private var regeneratingRetryTask: Task<Void, Never>?

    init(
        client: MastodonClient,
        streamingHub: StreamingHub,
        tuning: TuningStore = AppDependencies.tuning,
        onUnauthorized: @escaping () -> Void
    ) {
        store = TimelineStore(pageSize: Self.pageSize) { query in
            try await client.homeTimeline(query)
        }
        self.client = client
        self.streamingHub = streamingHub
        self.tuning = tuning
        self.onUnauthorized = onUnauthorized
        viewController.onApproachingEnd = { [weak self] in self?.loadOlder(origin: .automatic) }
        viewController.onRetry = { [weak self] in self?.retry() }
        viewController.onVisibleStatusesChange = { [weak self] ids in self?.markRead(ids) }
        viewController.onInteractionSettle = { [weak self] in self?.interactionDidSettle() }
        streamingStatusView.install(in: viewController.collectionView)
        viewController.onGapSelect = { [weak self] id, direction in self?.loadGap(id, from: direction, isAutomatic: false) }
        viewController.onGapApproach = { [weak self] id, direction in self?.loadGap(id, from: direction, isAutomatic: true) }
        #if DEBUG
        viewController.debugActions = makeDebugActions()
        #endif
    }

    /// - Parameter origin: 電波の回復などでやり直すときは`.automatic`。レート制限で止められている間は送らない。
    func start(origin: RequestOrigin = .user) {
        guard !isStopped else { return }
        viewController.setContentState(.loading)
        run(origin) { await $0.loadInitial() }
    }

    /// 読み込みを打ち切り、以後の結果を捨てる。ログアウトなどで画面を捨てるときに呼ぶ。
    func stop() {
        isStopped = true
        stopStreaming()
        cancelRegeneratingRetry()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// バックグラウンドに入るときに呼ぶ。バックグラウンドでは接続が止められるため自分から切り、既読位置を保存する。
    func enterBackground() {
        isInForeground = false
        stopStreaming()
        // 戻ったときは、つなぎ直したところで補完する。
        cancelRegeneratingRetry()
        saveReadPosition(inBackground: true)
    }

    /// バックグラウンドから戻ったときに呼ぶ。つなぎ直して切れていた間の投稿を補い、他の端末で読み進めた位置を取り込む。
    /// 最初の読み込みが済んでいなければ、済んだ時点でつなぐので何もしない。
    func enterForeground() {
        isInForeground = true
        guard !isStopped else { return }
        // バックグラウンドにいる間に電波が戻ったり、レート制限が明けたりしても、その知らせでは読み込まない。戻ったここでやり直す。
        retryFailedLoads()
        guard hasLoadedInitial else { return }
        startStreaming()
        syncReadPosition()
    }

    /// 電波が戻ったときや、レート制限が明けたときに呼ぶ。失敗したままの読み込みと、切れているストリーミングをすぐやり直す。
    func recover() {
        guard !isStopped, isInForeground else { return }
        autoLoadFailedGapIDs.removeAll()
        // 切れていれば、セッションがつなぎ直させ、つながったところで切れていた間を補う。
        if hasLoadedInitial, streamingHub.isConnected {
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

    private func stopStreaming() {
        guard let streamingSubscription else { return }
        logger.info("home streaming unsubscribe")
        streamingSubscription.cancel()
        self.streamingSubscription = nil
        // 購読をやめた後は知らせが届かないので、出していた表示を消す。
        viewController.setOutageNotice(false)
    }

    /// - Parameter origin: 自動の読み込みなら`.automatic`。レート制限で止められている間は送らずに失敗させる。
    private func run(_ origin: RequestOrigin = .user, _ operation: @escaping @MainActor (HomeTimelineController) async -> Void) {
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
        logger.info("home loadInitial start")
        do {
            let markerID = try await loadMarker()
            guard let statuses = try await store.loadInitial(around: markerID), !isStopped else { return }
            // 前回読んだところから続きを読めるよう、既読位置の投稿を最上部に置く。新しい投稿はその上にある。
            let topID = markerID.flatMap { id in store.statuses.contains { $0.id == id } ? TimelineEntry.ID.status(id) : nil }
            viewController.setEntries(store.entries, placingAtTop: topID)
            updateUnreadCount()
            hasLoadedInitial = true
            viewController.setContentState(store.isEmpty && store.isRegenerating ? .regenerating : .loaded)
            viewController.setFooterState(store.reachedEnd ? .reachedEnd : .idle)
            logger.info("home loadInitial done count=\(statuses.count, privacy: .public) regenerating=\(self.store.isRegenerating, privacy: .public)")
            startStreaming()
        } catch {
            handle(error, during: "loadInitial") { viewController.setContentState(.failed($0)) }
        }
    }

    private func loadOlder(origin: RequestOrigin = .user) {
        guard !isStopped, !store.isLoading, !store.reachedEnd, !store.isEmpty else { return }
        viewController.setFooterState(.loading)
        run(origin) { controller in
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
        guard !isStopped, isInForeground, streamingSubscription == nil else { return }
        streamingSubscription = streamingHub.subscribe(.user) { [weak self] activity in
            self?.streamingDidChange(activity)
        }
    }

    private func streamingDidChange(_ activity: StreamingHub.Activity) {
        guard !isStopped else { return }
        switch activity {
        case .connected:
            logger.info("home streaming connected")
            fillFromLatest()
        case .event(let event):
            receive(event)
        case .poll:
            logger.info("home poll")
            fillFromLatest()
        case .outage(let isOngoing):
            viewController.setOutageNotice(isOngoing)
        }
    }

    /// つながるたびと、つながらない間のポーリングで、切れていた間の投稿を読む。1ページに収まらなければギャップを置く。
    private func fillFromLatest() {
        #if DEBUG
        // 補完で読んだ新着はストアへ直接合流し、insertPendingの保留を通らないため、保留中は補完を始めない。
        // 保留を送る前に始まった補完は止めない。その結果は、保留中でも一覧に入る。
        if DebugFaults.isHoldingArrivals {
            isFillHeld = true
            logger.info("home fill held")
            return
        }
        #endif
        run(.automatic) { controller in
            do {
                let before = controller.store.entries
                let maxPages = Int(controller.tuning.value(of: TuningCatalog.fillPageLimit))
                guard let added = try await controller.store.fillFromLatest(maxPages: maxPages), !controller.isStopped else { return }
                controller.logger.info("home fill done added=\(added.count, privacy: .public) gaps=\(controller.store.gaps.count, privacy: .public) regenerating=\(controller.store.isRegenerating, privacy: .public)")
                if controller.store.isRegenerating {
                    controller.scheduleRegeneratingRetry()
                }
                // 待っている間に同じ投稿がストリーミングで挿入されていても、ギャップだけが増えていることがある。
                guard controller.store.entries != before else { return }
                controller.showEntries()
                if before.isEmpty {
                    // 空のホームへ最新のページを読んだ。その先に古い投稿が残っているかもしれない。
                    controller.viewController.setFooterState(controller.store.reachedEnd ? .reachedEnd : .idle)
                }
            } catch {
                // 失敗しても、次につながったときに同じ基準から読み直す。
                controller.handle(error, during: "fill") { _ in }
                // 作り直し中の読み直しが失敗したら、つながったままでは次のきっかけが来ないので、読み直しを続ける。
                if controller.store.isRegenerating {
                    controller.scheduleRegeneratingRetry()
                }
            }
        }
    }

    /// サーバーがホームを作り直している最中で結果が揃っていなかったので、時間をおいて補完を読み直す。
    /// つながりが安定していると、次に補完するきっかけが来ず、作り直しの後に揃った投稿が届かないため。
    private func scheduleRegeneratingRetry() {
        guard regeneratingRetryTask == nil, !isStopped, isInForeground else { return }
        let interval = tuning.value(of: TuningCatalog.regeneratingRetryInterval)
        logger.info("home regenerating retry scheduled after=\(interval, privacy: .public)")
        regeneratingRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            regeneratingRetryTask = nil
            guard !isStopped, isInForeground else { return }
            fillFromLatest()
        }
    }

    private func cancelRegeneratingRetry() {
        regeneratingRetryTask?.cancel()
        regeneratingRetryTask = nil
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
        viewController.setGapStates(loading: store.loadingGapIDs.union([id]), failures: store.gapFailures.filter { $0.key != id })
        let gapBefore = store.gaps.first { $0.id == id }
        run(isAutomatic ? .automatic : .user) { controller in
            controller.logger.info("home loadGap start id=\(id, privacy: .public) direction=\(String(describing: direction), privacy: .public) automatic=\(isAutomatic, privacy: .public)")
            do {
                let added = try await controller.store.loadGap(id, from: direction)
                guard !controller.isStopped else { return }
                // 再生成中の空の結果などでギャップが縮まなければ、描き直しの後にすぐ同じギャップを読み直してしまうため、
                // 失敗と同じくタップされるまで自動では読まない。
                if isAutomatic, added?.isEmpty == true, controller.store.gaps.contains(where: { $0 == gapBefore }) {
                    controller.autoLoadFailedGapIDs.insert(id)
                }
                controller.showGapStates()
                guard let added else { return }
                controller.viewController.setEntries(controller.store.entries, keeping: anchorID)
                controller.updateUnreadCount()
                controller.logger.info("home loadGap done added=\(added.count, privacy: .public)")
            } catch {
                if isAutomatic {
                    controller.autoLoadFailedGapIDs.insert(id)
                }
                controller.showGapStates()
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

    // MARK: - 既読位置

    /// 既読位置はタイムラインを読む助けで、読めなくてもタイムラインは表示できるため、トークンの失効以外の失敗では位置なしで進める。
    private func loadMarker() async throws -> String? {
        do {
            return try await client.marker(for: .home)
        } catch let error as MastodonAPIError where error.isUnauthorized {
            throw error
        } catch is FeatureUnavailable {
            return nil
        } catch {
            logger.error("home marker load failed: \(SciaLog.describe(error), privacy: .public)")
            return nil
        }
    }

    private func syncReadPosition() {
        run(.automatic) { controller in
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
        // 既読位置の保存は、スクロールやバックグラウンドへの移行で自動で送る。
        RequestOrigin.$current.withValue(.automatic) {
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
        #if DEBUG
        // 保留を解いたときに、releaseHeldArrivalsから挿入する。
        guard !DebugFaults.isHoldingArrivals else {
            logger.info("home insert pending held")
            return
        }
        #endif
        let added = store.flushPending()
        logger.info("home insert pending added=\(added.count, privacy: .public)")
        guard !added.isEmpty else { return }
        showEntries()
    }

    /// 自動の補完の中でギャップを読めなかったときも、並びと一緒に読めなかった表示にする。
    private func showEntries() {
        showGapStates()
        viewController.setEntries(store.entries)
        updateUnreadCount()
    }

    private func showGapStates() {
        viewController.setGapStates(loading: store.loadingGapIDs, failures: store.gapFailures)
    }

    private func markRead(_ ids: [Status.ID]) {
        store.markRead(ids)
        updateUnreadCount()
    }

    private func updateUnreadCount() {
        viewController.setUnreadCount(store.unreadCount, isLowerBound: store.hasUnloadedUnread)
    }

    private func handle(_ error: any Error, during operation: String, show: (ErrorPresentation) -> Void) {
        // 止めた後に届いた結果や、止めたことによる取り消しは、もう画面に関係しない。
        guard !isStopped, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        // 既読位置の保存など、このサーバーでは使えないと分かって止めた機能。止めたことは記録してあり、使う人に見せることもない。
        guard !(error is FeatureUnavailable) else { return }
        logger.error("home \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized()
        }
        show(ErrorPresentation(error))
    }
}

#if DEBUG
// MARK: - 検証用

extension HomeTimelineController {
    /// 投稿しなくても、新着の挿入やギャップの表示をシミュレーターで確かめるための操作。
    fileprivate func makeDebugActions() -> [UIMenuElement] {
        [
            UIMenu(title: "ダミー投稿を流す", image: UIImage(systemName: "square.stack"), children: DebugDummyPost.allCases.map { post in
                UIAction(title: post.title, image: UIImage(systemName: post.systemImage)) { [weak self] _ in
                    self?.streamDummy(post)
                }
            }),
            UIAction(title: "直近の投稿を取りこぼして再接続", image: UIImage(systemName: "bolt.horizontal")) { [weak self] _ in
                self?.simulateMissedWhileDisconnected()
            },
        ]
    }

    /// サーバーにない検証用の投稿か。リンクカードの取り直しから外すために使う。
    func isDebugLocalOnly(_ id: Status.ID) -> Bool {
        store.debugLocalOnlyIDs.contains(id)
    }

    /// デバッグメニューや、URLで指定したダミー投稿を流す。
    func streamDummy(_ post: DebugDummyPost) {
        logger.info("debug stream dummy \(post.rawValue, privacy: .public)")
        switch post {
        case .arrivals:
            streamDummyArrivals(count: 10)
        case .images:
            streamDummyMediaStatus(content: "ビューアの確認用に4枚の画像を添付", attachments: DummyMedia.attachments)
        case .tall:
            streamDummyMediaStatus(content: "ビューアの確認用に縦長の画像を1枚添付", attachments: DummyMedia.singleTallAttachment)
        case .transparent:
            streamDummyMediaStatus(content: "ビューアの確認用に透明な部分のある画像を1枚添付", attachments: DummyMedia.singleTransparentAttachment)
        case .video:
            streamDummyVideoStatus(content: "ビューアの確認用に動画とGIFを1本ずつ添付", make: DummyMedia.videoAttachments)
        case .longVideo:
            streamDummyVideoStatus(content: "ビューアの確認用に、毎秒音が鳴る90秒の動画を添付", make: DummyMedia.longVideoAttachment)
        case .linkCard:
            streamDummyLinkCard(withImage: false)
        case .linkCardImage:
            streamDummyLinkCard(withImage: true)
        case .linkCardSensitive:
            streamDummyLinkCard(withImage: true, sensitive: true)
        }
    }

    /// サーバーのカードが後から届くまでの秒数。届く瞬間に合わせて、スクロールなどの操作を送れるよう、少し長めにする。
    static let dummyLinkCardDelay: Duration = .seconds(5)

    /// リンクだけのダミーの投稿を新着と同じ経路で流し、`dummyLinkCardDelay`のあとに、通信せずにカードを届ける。
    /// カードが届いたときの動きを、サーバーがカードを付ける時機によらず、何度でも同じ条件で確かめるため。
    /// - Parameter sensitive: 閲覧注意の投稿にする。届いたカードの画像を覆うところを確かめる。
    private func streamDummyLinkCard(withImage: Bool, sensitive: Bool = false) {
        let avatar = store.statuses.first?.account.avatar ?? client.credential.instance
        let base = Self.dummyStatus(number: 1, avatar: avatar)
        guard let link = URL(string: "https://news.example/articles/\(base.id)") else { return }
        let dummy = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（リンクカード）", avatar: avatar),
            content: #"<p>リンクカードが届くときの確認用 <a href="\#(link.absoluteString)">news.example/articles/\#(base.id)</a></p>"#,
            spoilerText: "",
            url: nil,
            sensitive: sensitive
        )
        let card = PreviewCard(
            url: link,
            title: "ダミーの記事の見出し",
            description: "5秒後に届いたダミーのカード。",
            type: .link,
            providerName: withImage ? "News Example" : "",
            image: withImage ? CatalogFixtures.imageURL(width: 400, height: 225, color: .systemIndigo) : nil,
            width: withImage ? 400 : 0,
            height: withImage ? 225 : 0,
            blurhash: withImage ? CatalogFixtures.blurhash : nil
        )
        // 取り直しで届くのと同じく、カードの付いた同じ版の投稿として渡す。
        let carded = Status(
            id: dummy.id,
            createdAt: dummy.createdAt,
            account: dummy.account,
            content: dummy.content,
            spoilerText: "",
            url: nil,
            sensitive: sensitive,
            card: card
        )
        run { controller in
            controller.store.debugLocalOnlyIDs.insert(dummy.id)
            controller.receive(.update(dummy))
            guard (try? await Task.sleep(for: Self.dummyLinkCardDelay)) != nil, !controller.isStopped else { return }
            controller.updateStatus(dummy.id) { $0.adoptingCard(of: carded) }
        }
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

    /// ビューアを確かめるための、画像付きのダミーの投稿を、新着と同じ経路で1件流す。
    /// 画像は端末で描くため、通信せず、実際の投稿を探さずに確かめられる。
    /// - Parameter attachments: 投稿のIDを受け取り、添付ファイルを返す。
    private func streamDummyMediaStatus(content: String, attachments: (String) -> [MediaAttachment]) {
        let avatar = store.statuses.first?.account.avatar ?? client.credential.instance
        let base = Self.dummyStatus(number: 1, avatar: avatar)
        let dummy = Status(
            id: base.id,
            createdAt: base.createdAt,
            account: Account(id: "dummy", username: "dummy", acct: "dummy", displayName: "ダミー（画像）", avatar: avatar),
            content: content,
            spoilerText: "",
            url: nil,
            mediaAttachments: attachments(base.id)
        )
        run { controller in
            controller.store.debugLocalOnlyIDs.insert(dummy.id)
            controller.receive(.update(dummy))
        }
    }

    /// 動画を付けたダミー投稿を流す。動画は初回だけ端末で書き出すため、少し遅れて流れる。
    private func streamDummyVideoStatus(content: String, make: @escaping () async throws -> (String) -> [MediaAttachment]) {
        Task {
            do {
                let attachments = try await make()
                streamDummyMediaStatus(content: content, attachments: attachments)
            } catch {
                SciaLog.logger(category: "media").error("dummy video failed: \(error.localizedDescription, privacy: .public)")
            }
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

/// ホームに流せるダミー投稿の種類。デバッグメニューの項目と、URL（`scia-debug://dummy/<rawValue>`）の名前を兼ねる。
enum DebugDummyPost: String, CaseIterable {
    case arrivals
    case images
    case tall
    case transparent
    case video
    case longVideo = "long-video"
    case linkCard = "link-card"
    case linkCardImage = "link-card-image"
    case linkCardSensitive = "link-card-sensitive"

    var title: String {
        switch self {
        case .arrivals: "新着10件"
        case .images: "画像4枚"
        case .tall: "縦長の画像1枚"
        case .transparent: "透過画像1枚"
        case .video: "動画とGIF"
        case .longVideo: "音声付きの長い動画"
        case .linkCard: "後から届くリンクカード（画像なし）"
        case .linkCardImage: "後から届くリンクカード（画像あり）"
        case .linkCardSensitive: "後から届くリンクカード（閲覧注意）"
        }
    }

    var systemImage: String {
        switch self {
        case .arrivals: "text.badge.plus"
        case .images: "photo.badge.plus"
        case .tall: "rectangle.portrait"
        case .transparent: "circle.dashed"
        case .video: "play.rectangle"
        case .longVideo: "speaker.wave.2"
        case .linkCard, .linkCardImage, .linkCardSensitive: "link"
        }
    }
}
#endif
