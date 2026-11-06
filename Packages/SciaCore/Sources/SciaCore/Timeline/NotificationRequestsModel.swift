import Foundation
import os

/// 保留中の通知の一覧の読み込みと、受け入れと無視の通信を受け持ち、結果を一覧の画面（`TimelineDisplay`）へ命令として伝える。決まりはdocs/notification-filter.mdにある。
///
/// ストリームがないため購読せず、開いたときと、引っぱって読み直したときに読む。
@MainActor
public final class NotificationRequestsModel {
    /// 1回に読む件数。APIの上限は80件。
    private static let pageSize = 40

    /// 結果を伝える一覧の画面。
    public weak var display: (any TimelineDisplay)?
    /// 受け入れか無視に失敗したときに呼ぶ。知らせ方は作る側が決める。
    public var onFailure: (NotificationRequestDecision, ErrorPresentation) -> Void = { _, _ in }
    /// 受け入れか無視が済んだときに呼ぶ。保留の人数の読み直しと、受け入れた通知の取り込みを待つのに使う。
    public var onAnswered: (NotificationRequestDecision) -> Void = { _ in }
    /// サーバーが返す順。
    public private(set) var requests: [NotificationRequest] = []
    private var reachedEnd = false
    private var isLoading = false
    private var nextMaxID: String?
    /// 答えを送っている途中のまとまり。重ねて送らない。
    private var answeringIDs: Set<String> = []
    /// 答えたまとまり。答える前に送った読み込みの応答に入っていても、並べ直さない。
    private var answeredIDs: Set<String> = []
    private let client: MastodonClient
    /// この一覧が始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときにも閉じる。
    private let tasks: TaskScope
    /// APIが401を返したときに呼ぶ。ログアウトされたとして止め、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "notificationRequests")
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    public var runningTaskCount: Int { tasks.runningCount }

    public init(client: MastodonClient, tasks: TaskScope, onUnauthorized: @escaping () -> Void) {
        self.client = client
        self.tasks = tasks
        self.onUnauthorized = onUnauthorized
    }

    /// - Parameter purpose: 使う人が開いたり再試行を押したりしたときは`.action`。
    @discardableResult
    public func start(purpose: RequestPurpose) -> Task<Void, Never>? {
        display?.setContentState(.loading)
        return tasks.run(purpose) { [weak self] in
            guard let self else { return }
            do {
                guard try await loadFirstPage() else { return }
                display?.setContentState(.loaded)
            } catch {
                handle(error, during: "loadInitial") { self.display?.setContentState(.failed($0)) }
            }
        }
    }

    /// 引っぱって離したときに、最初のページから読み直して置き換える。読めなかったら前の一覧のまま残す。
    public func refresh() async {
        if requests.isEmpty {
            await start(purpose: .action)?.value
            return
        }
        await tasks.run(.action) { [weak self] in
            guard let self else { return }
            do {
                _ = try await loadFirstPage()
            } catch {
                handle(error, during: "refresh") { _ in }
            }
        }?.value
    }

    /// 末尾が近づいたときに呼ぶ。
    public func approachEnd() {
        loadOlder(purpose: .display)
    }

    /// 失敗の表示の再試行が押されたときに呼ぶ。
    public func retry() {
        if requests.isEmpty {
            start(purpose: .action)
        } else {
            loadOlder(purpose: .action)
        }
    }

    /// 最初のページで置き換える。読み込み中ならfalse。
    private func loadFirstPage() async throws -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        let page = try await client.notificationRequests(maxID: nil, limit: Self.pageSize)
        guard !tasks.isClosed else { return false }
        requests = []
        apply(page, after: nil)
        logger.info("notificationRequests load done count=\(self.requests.count, privacy: .public)")
        return true
    }

    private func loadOlder(purpose: RequestPurpose) {
        guard !isLoading, !reachedEnd, let maxID = nextMaxID, !requests.isEmpty else { return }
        isLoading = true
        display?.setFooterState(.loading)
        tasks.run(purpose) { [weak self] in
            guard let self else { return }
            defer { isLoading = false }
            do {
                let page = try await client.notificationRequests(maxID: maxID, limit: Self.pageSize)
                guard !tasks.isClosed else { return }
                apply(page, after: maxID)
            } catch {
                handle(error, during: "loadOlder") { self.display?.setFooterState(.failed($0)) }
            }
        }
    }

    /// 同じ位置を返し続けるサーバーで同じページを読み続けないよう、続きの位置が進まなければ終わりにする。
    private func apply(_ page: NotificationRequestPage, after maxID: String?) {
        var seen = Set(requests.map(\.id)).union(answeredIDs)
        requests += page.requests.filter { seen.insert($0.id).inserted }
        nextMaxID = page.nextMaxID
        reachedEnd = page.nextMaxID == nil || page.nextMaxID == maxID || page.requests.isEmpty
        // 読み込みで増える行は、操作によらない変化なので動かさない。
        show(animatesRemoval: false)
        display?.setFooterState(reachedEnd ? .reachedEnd : .idle)
    }

    private func show(animatesRemoval: Bool) {
        display?.show(requests.map(TimelineEntry.notificationRequest), animatesRemoval: animatesRemoval)
    }

    // MARK: - 答える

    /// 受け入れるか無視する。確かめずにすぐ送る。済んだら行を消す。済んだかは、終えてから`isAnswered(_:)`で分かる。
    /// 送っている途中のまとまりには、重ねて送らずnilを返す。
    @discardableResult
    public func answer(_ request: NotificationRequest, _ decision: NotificationRequestDecision) -> Task<Void, Never>? {
        guard !answeringIDs.contains(request.id), !answeredIDs.contains(request.id) else { return nil }
        logger.info("notificationRequests answer start decision=\(String(describing: decision), privacy: .public)")
        let task = tasks.run(.action) { [weak self] in
            guard let self else { return }
            defer { answeringIDs.remove(request.id) }
            do {
                try await client.answerNotificationRequest(request.id, decision)
            } catch let error as MastodonAPIError where error.statusCode == 404 {
                // もうない（ほかの端末で片づけたなど）。保留中に残らないことは変わらないので、済んだときと同じく消す。
                logger.info("notificationRequests answer found nothing")
            } catch {
                handle(error, during: "answer") { self.onFailure(decision, $0) }
                return
            }
            guard !tasks.isClosed else { return }
            logger.info("notificationRequests answer done")
            answeredIDs.insert(request.id)
            requests.removeAll { $0.id == request.id }
            // 使う人の操作で消える行なので、閉じる動きで消す。
            show(animatesRemoval: true)
            onAnswered(decision)
        }
        if task != nil {
            answeringIDs.insert(request.id)
        }
        return task
    }

    /// 受け入れたか無視したまとまりか。
    public func isAnswered(_ id: NotificationRequest.ID) -> Bool {
        answeredIDs.contains(id)
    }

    private func handle(_ error: any Error, during operation: String, show: (ErrorPresentation) -> Void) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled, !tasks.isClosed else { return }
        logger.error("notificationRequests \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized()
        }
        show(ErrorPresentation(error))
    }
}

/// 保留中の通知の1人分の、その人からの通知の一覧。通知のタブと同じまとめ方で、保留していない通知も並べる。決まりはdocs/notification-filter.mdにある。
/// ストリーミング、既読位置、未読の数は持たない。
@MainActor
public final class AccountNotificationsModel {
    private static let pageSize = 40

    public weak var display: (any TimelineDisplay)?
    public let filtering: StatusFiltering
    private let store: NotificationStore
    private let tasks: TaskScope
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "accountNotifications")
    public var runningTaskCount: Int { tasks.runningCount }

    public init(accountID: String, client: MastodonClient, tasks: TaskScope, onUnauthorized: @escaping () -> Void) {
        let filtering = StatusFiltering(context: .notifications, myAccountID: client.credential.accountID)
        self.filtering = filtering
        store = NotificationStore(pageSize: Self.pageSize, filtering: filtering) { query in
            try await client.notifications(query, from: accountID)
        }
        self.tasks = tasks
        self.onUnauthorized = onUnauthorized
    }

    @discardableResult
    public func start(purpose: RequestPurpose) -> Task<Void, Never>? {
        display?.setContentState(.loading)
        return tasks.run(purpose) { [weak self] in
            guard let self else { return }
            do {
                guard try await loadFirstPage() else { return }
                display?.setContentState(.loaded)
            } catch {
                handle(error, during: "loadInitial") { self.display?.setContentState(.failed($0)) }
            }
        }
    }

    /// 引っぱって離したときに、最新のページから読み直して置き換える。読めなかったら前の一覧のまま残す。
    public func refresh() async {
        if store.isEmpty {
            await start(purpose: .action)?.value
            return
        }
        await tasks.run(.action) { [weak self] in
            guard let self else { return }
            do {
                _ = try await loadFirstPage()
            } catch {
                handle(error, during: "refresh") { _ in }
            }
        }?.value
    }

    public func approachEnd() {
        loadOlder(purpose: .display)
    }

    public func retry() {
        if store.isEmpty {
            start(purpose: .action)
        } else {
            loadOlder(purpose: .action)
        }
    }

    private func loadFirstPage() async throws -> Bool {
        guard let notifications = try await store.loadInitial(), !tasks.isClosed else { return false }
        display?.show(store.entries)
        display?.setFooterState(store.reachedEnd ? .reachedEnd : .idle)
        logger.info("accountNotifications load done count=\(notifications.count, privacy: .public)")
        return true
    }

    private func loadOlder(purpose: RequestPurpose) {
        guard !store.isLoading, !store.reachedEnd, !store.isEmpty else { return }
        display?.setFooterState(.loading)
        tasks.run(purpose) { [weak self] in
            guard let self else { return }
            do {
                guard try await store.loadOlder() != nil, !tasks.isClosed else { return }
                display?.show(store.entries)
                display?.setFooterState(store.reachedEnd ? .reachedEnd : .idle)
            } catch {
                handle(error, during: "loadOlder") { self.display?.setFooterState(.failed($0)) }
            }
        }
    }

    /// 投稿の操作（お気に入りなど）の結果を、並べている通知の投稿に当てる。
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        guard store.updateStatus(id, transform) else { return }
        display?.show(store.entries)
    }

    /// 削除された投稿の通知を除く。
    public func removeStatus(_ id: Status.ID) {
        guard store.removeStatus(id) else { return }
        display?.show(store.entries, animatesRemoval: true)
    }

    /// ミュートしたハッシュタグの付いた投稿の通知を除く。通知の一覧と同じく、解除しても読み込み直すまで戻さない。
    public func setTag(_ name: String, excluded: Bool) {
        guard excluded else {
            store.includeTag(name)
            return
        }
        guard store.excludeTag(name) else { return }
        display?.show(store.entries, animatesRemoval: true)
    }

    /// 通知を隠すミュートか、ブロックをした相手からの通知を除く。通知の一覧と同じく、解除しても読み込み直すまで戻さない。
    public func setAccount(_ id: String, excluded: Bool) {
        guard excluded else {
            store.includeAccount(id)
            return
        }
        guard store.excludeAccount(id) else { return }
        display?.show(store.entries, animatesRemoval: true)
    }

    /// 片づけたフォローリクエストの通知と、同じユーザーからのリクエストの通知を除く。
    public func removeFollowRequests(answering request: MastodonNotification) {
        guard store.removeFollowRequests(answering: request) else { return }
        display?.show(store.entries, animatesRemoval: true)
    }

    /// 通知のメニューで削除した通知を除く。
    public func removeNotification(_ notification: MastodonNotification) {
        guard store.removeNotification(notification.id, groupKey: notification.groupKey) else { return }
        display?.show(store.entries, animatesRemoval: true)
    }

    private func handle(_ error: any Error, during operation: String, show: (ErrorPresentation) -> Void) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled, !tasks.isClosed else { return }
        logger.error("accountNotifications \(operation, privacy: .public) failed: \(SciaLog.describe(error), privacy: .public)")
        if let apiError = error as? MastodonAPIError, apiError.isUnauthorized {
            onUnauthorized()
        }
        show(ErrorPresentation(error))
    }
}
