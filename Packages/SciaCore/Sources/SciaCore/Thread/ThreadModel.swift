import Foundation
import os

/// スレッドの読み込みとストリーミングを受け持ち、ThreadStoreの並びを一覧の画面（`TimelineDisplay`）へ命令として伝える。
///
/// 押した投稿だけを並べて開き、会話を読んだら、押した投稿の位置を保ったまま、祖先を上に、返信を下に足す。
/// 開いている間は、ホームのストリームに届いた投稿から、スレッドへの返信と、スレッドの中の投稿の編集と削除を拾う。
@MainActor
public final class ThreadModel {
    /// 結果を伝える一覧の画面。
    public weak var display: (any TimelineDisplay)?
    /// スレッドで当てるサーバーのフィルター。画面の警告の折りたたみにも同じものを使う。
    public let filtering: StatusFiltering
    /// 画面を移る動きの最中なら、移り終わってから`work`を行う。移る途中に行を足すと、メインスレッドが止まって動きが跳ぶため。作る側が、画面の動きに合わせて渡す。
    public var afterTransition: (_ work: @escaping @MainActor () -> Void) -> Void = { $0() }
    /// 最初の会話を並べ終えたときに呼ぶ。開く動きのために空けていた余白を戻すなど、画面の側の後始末に使う。
    public var onFirstLoadShown: (() -> Void)?
    private let store: ThreadStore
    private let client: MastodonClient
    private let streamingHub: StreamingHub
    private var streamingSubscription: StreamingHub.Subscription?
    private var isInForeground = true
    /// 会話を一度読み終えた。読み直しでは、押した投稿も読み直して編集を取り込む。
    private var hasLoaded = false
    public private(set) var loadTask: Task<Void, Never>?
    /// 会話を読んでいる途中。つないだときやポーリングで、読み込みを重ねない。
    private var isLoading = false
    /// 会話の読み込みの状態。フッターに出す。
    public private(set) var footerState = TimelineFooterState.idle
    /// 読み込みが401で失敗したときに呼ぶ。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "thread")
    /// この画面が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときと、画面を閉じてこのモデルが捨てられたときに閉じる。
    private let tasks: TaskScope

    public init(focus: Status, client: MastodonClient, streamingHub: StreamingHub, tasks: TaskScope, onUnauthorized: @escaping () -> Void) {
        self.tasks = tasks
        let filtering = StatusFiltering(context: .thread, myAccountID: client.credential.accountID)
        self.filtering = filtering
        store = ThreadStore(focus: focus, filtering: filtering)
        self.client = client
        self.streamingHub = streamingHub
        self.onUnauthorized = onUnauthorized
        tasks.onClose { [weak self] in
            self?.streamingSubscription?.cancel()
            self?.streamingSubscription = nil
        }
    }

    isolated deinit {
        streamingSubscription?.cancel()
    }

    /// 走り終えていない処理の数。閉じたあとに何も起きないことを、テストが確かめるのに使う。
    public var runningTaskCount: Int { tasks.runningCount }

    public var focusID: Status.ID { store.focusID }

    /// 画面に積む前に呼ぶ。押した投稿だけを並べ、会話を読み始める。
    public func start() {
        display?.show(store.entries)
        load()
        startStreaming()
    }

    /// 一覧を引っぱって離したときに、会話と押した投稿を読み直す。スレッドは上に新しい投稿が来る並びではないため、全体を読み直す。
    public func refresh() async {
        logger.info("thread refresh")
        load()
        await loadTask?.value
    }

    /// 失敗の表示の再試行が押されたときに呼ぶ。
    public func retry() {
        load()
    }

    private func setFooterState(_ state: TimelineFooterState) {
        footerState = state
        display?.setFooterState(state)
    }

    /// 会話を読む。読んだ結果は、押した投稿の位置を保って並べる。
    private func load() {
        guard !tasks.isClosed else { return }
        setFooterState(.loading)
        loadTask?.cancel()
        store.beginLoading()
        isLoading = true
        let reloadsFocus = hasLoaded
        loadTask = tasks.run { [weak self] in
            guard let self else { return }
            // 止められた読み込みは、止めた側が始めた読み込みの途中に終わるため、読み込み中を下ろさない。
            defer {
                if !Task.isCancelled { isLoading = false }
            }
            do {
                // 読み直しでは、切れている間の押した投稿の編集も取り込む。会話の応答には押した投稿が含まれないため。
                async let focus = reloadsFocus ? client.status(store.focusID) : nil
                let context = try await client.statusContext(store.focusID)
                let updatedFocus = try await focus
                guard !Task.isCancelled else { return }
                store.apply(context, focus: updatedFocus)
                let isFirstLoad = !hasLoaded
                hasLoaded = true
                afterTransition { [weak self] in
                    self?.showLoaded(isFirstLoad: isFirstLoad)
                }
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("thread context failed: \(SciaLog.describe(error), privacy: .public)")
                if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
                    onUnauthorized()
                }
                setFooterState(.failed(ErrorPresentation(error)))
            }
        }
    }

    private func showLoaded(isFirstLoad: Bool) {
        guard let display else { return }
        let focus = TimelineEntry.ID.status(store.focusID)
        // 読み直しでは、読んでいる位置を保つ。
        display.show(store.entries, keeping: isFirstLoad ? focus : nil)
        setFooterState(.idle)
        guard isFirstLoad else { return }
        onFirstLoadShown?()
    }

    /// 投稿への操作の結果を反映する。
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard store.updateStatus(id, transform) else { return }
        display?.show(store.entries)
    }

    /// 削除した投稿を除く。使う人の操作の結果なので、閉じて詰める動きで消す。
    public func removeStatus(_ id: Status.ID) {
        guard store.removeStatus(id) else { return }
        display?.show(store.entries, animatesRemoval: true)
    }

    /// 投稿欄から送った投稿を、ストリーミングで届くのを待たずに足す。スレッドへの返信でなければ何もしない。
    public func receivePosted(_ status: Status) {
        guard store.receive(.update(status)) else { return }
        display?.show(store.entries)
    }

    // MARK: - ストリーミング

    /// バックグラウンドでは接続が止められるため、ホームと同じく購読をやめる。
    public func enterBackground() {
        isInForeground = false
        streamingSubscription?.cancel()
        streamingSubscription = nil
    }

    /// 戻ったら購読し直す。つながったところで、切れていた間の返信を読み直す。
    public func enterForeground() {
        isInForeground = true
        startStreaming()
    }

    private func startStreaming() {
        guard isInForeground, !tasks.isClosed, streamingSubscription == nil else { return }
        streamingSubscription = streamingHub.subscribe(.user) { [weak self] activity in
            self?.streamingDidChange(activity)
        }
    }

    private func streamingDidChange(_ activity: StreamingHub.Activity) {
        switch activity {
        case .connected, .poll:
            // 読んでいる途中なら、その読み込みが補う。最初の読み込みに失敗していれば、ここで読み直す。
            guard !isLoading else { return }
            load()
        case .event(let event):
            // 使う人の操作によらない変化なので、削除も閉じる動きにせず、読んでいる行を動かさない。
            guard store.receive(event) else { return }
            display?.show(store.entries)
        case .outage:
            break
        }
    }
}
