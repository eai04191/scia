import Foundation

/// 通知を新しい順に持つ。RESTで読んだページと、ストリーミングで届いた通知を合わせる。
///
/// ホームと違い、ギャップは置かない。通知は上から読むもので、切れていた間に読み切れないほど溜まったら、
/// 古い側を捨てて最新の側から読み直せば足りるため。
@MainActor
public final class NotificationStore {
    public typealias Fetch = @Sendable (TimelineQuery) async throws -> NotificationPage

    /// 新しい順。フィルターで出さない投稿についての通知も含める。続きを読む位置に使うため。
    public private(set) var notifications: [MastodonNotification] = []
    /// 読めなかった通知。新しい順。同じIDの通知が読めたら外す。
    public private(set) var unreadable: [UnreadableItem] = []
    /// これより古い通知はない。
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false
    /// ストリーミングで届き、まだ挿入していない通知。届いた順。
    public private(set) var pending: [MastodonNotification] = []
    /// 見た中で最も新しい通知のID。これより新しい通知を未読として数える。
    public private(set) var lastReadID: String?
    /// サーバーのmarkerに保存されている既読位置。
    public private(set) var savedReadID: String?

    /// 削除した投稿のID。削除の前に読み始めたページや、遅れて届いた通知で、その投稿についての通知を戻さない。
    private var deletedStatusIDs: Set<Status.ID> = []
    /// 承認か却下で片づけたフォローリクエストの通知のID。サーバーは片づけた通知を消すが、その前に読み始めたページで戻さない。
    /// 同じ通知がそのページで読めなかったときも、読めなかった行として戻さない。
    private var resolvedFollowRequestIDs: Set<MastodonNotification.ID> = []
    /// 補完を始めたが、まだ成功していない基準のID。失敗した後に新着が挿入されて最新のIDが進んでも、次の補完はここから読む。
    private var unfilledSinceID: String?
    private var isFilling = false
    /// 補完の最中に再び補完を求められたときの基準のID。今の補完が終わったら、ここからもう一度読む。
    private var refillSinceID: String?
    /// 補完が古い側を捨てて、読み込む範囲を変えるたびに増やす。変わる前に読み始めた古いページを合流させないために使う。
    private var rangeGeneration = 0
    private let pageSize: Int
    private let filtering: StatusFiltering?
    private let fetch: Fetch

    /// - Parameter filtering: 通知の投稿に当てるサーバーのフィルター。nilなら当てない。
    public init(pageSize: Int, filtering: StatusFiltering? = nil, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.filtering = filtering
        self.fetch = fetch
    }

    /// 一覧に並べる通知と読めなかった通知。新しい順。フィルターで出さない投稿についての通知は含まない。
    public var entries: [TimelineEntry] {
        let now = Date()
        return (notifications.filter { !isFilteredOut($0, now: now) }.map { ($0.id, TimelineEntry.notification($0)) } + unreadable.map { ($0.id, TimelineEntry.unreadable($0)) })
            .sorted { StatusID.isNewer($0.0, than: $1.0) }
            .map(\.1)
    }

    /// 読めた通知も読めなかった通知もない。読めなかった通知しかなくても、続きは読めるため空ではない。
    public var isEmpty: Bool { notifications.isEmpty && unreadable.isEmpty }

    /// 読めた通知と読めなかった通知のID。新しい順。続きを読む位置に使う。
    /// 読めなかった通知も含めるのは、1ページの全部が読めなかったときにも、その先へ進めるようにするため。
    private var itemIDs: [String] {
        (notifications.map(\.id) + unreadable.map(\.id)).sorted { StatusID.isNewer($0, than: $1) }
    }

    /// 最新のページで置き換える。読み込み中なら何もせずnilを返す。`markerID`を渡すと、そこを既読位置にする。
    public func loadInitial(markerID: String? = nil) async throws -> [MastodonNotification]? {
        guard !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(TimelineQuery(limit: pageSize))
        notifications = Self.sorted(page.notifications.filter { !isDiscarded($0) })
        unreadable = Self.sorted(page.unreadable.filter { !resolvedFollowRequestIDs.contains($0.id) }, excluding: notifications)
        reachedEnd = page.isEmpty
        // 読んだ通知が全部フィルターで隠れて行が1つもないと、続きを読むきっかけがないため、並べる通知が出るまで古い方を読む。
        // 続きの読み込みに失敗したら空に戻す。隠した通知だけが残ると空でない扱いになり、読み込み直しが最初の読み込みからやり直さなくなるため。
        if entries.isEmpty, !reachedEnd, let oldestID = itemIDs.last {
            do {
                _ = try await fetchOlder(than: oldestID, generation: rangeGeneration)
            } catch {
                notifications = []
                unreadable = []
                reachedEnd = false
                throw error
            }
        }
        if let markerID {
            applySavedMarker(markerID)
        }
        return notifications
    }

    /// 末尾より古いページを読み、新たに足した通知を返す。
    /// 読み込み中、終端に達している、まだ1件もない場合は何もせずnilを返す。
    ///
    /// 読んでいる間に補完が古い側を捨てたら、読んだページは捨てた範囲の続きなので合流させず、空を返す。
    public func loadOlder() async throws -> [MastodonNotification]? {
        guard !isLoading, !reachedEnd, let oldestID = itemIDs.last else { return nil }
        isLoading = true
        defer { isLoading = false }

        return try await fetchOlder(than: oldestID, generation: rangeGeneration)
    }

    /// `oldestID`より古いページを読み、足した通知のうち一覧に並べたものを返す。
    /// 読んだ通知が全部フィルターで隠れたら、並べる通知か読めなかった通知が出るか、終わりに着くまで続けて読む。
    /// 一覧の末尾の行が画面に出ることが続きを読むきっかけなので、行が増えないと、そこで止まってしまうため。
    /// - Parameter generation: 読み始めたときの読み込む範囲。読んでいる間に補完が古い側を捨てたら、読んだページは捨てた範囲の続きなので合流させず、空を返す。
    private func fetchOlder(than oldestID: String, generation: Int) async throws -> [MastodonNotification] {
        var maxID = oldestID
        while true {
            let page = try await fetch(TimelineQuery(maxID: maxID, limit: pageSize))
            guard generation == rangeGeneration else { return [] }
            if page.isEmpty {
                reachedEnd = true
            }
            let added = merge(page)
            // 削除済みの投稿についての通知しかなかったときなど、続きを読む位置が進まなければ、同じページを読み続けないよう止める。
            guard added.isEmpty, !page.isEmpty, page.unreadable.isEmpty, let next = itemIDs.last, next != maxID else {
                return added
            }
            maxID = next
        }
    }

    /// ストリーミングが切れていた間の通知を読み、新たに加わった通知を新しい順に返す。補完の最中ならnilを返す。
    ///
    /// 手元で最も新しい通知より新しいものを、最新の側から手元とつながるまで`maxPages`ページまで読む。
    /// つながらなければ、読んだ中で最も古い通知より古い手元の通知を捨て、そこから古い方は`loadOlder()`で読み直す。
    /// 間を欠いたまま並べないため。
    ///
    /// 失敗したときは何も反映せず、次の呼び出しも同じ基準から読む。補完の最中に呼ばれたら、
    /// そのときの基準を覚えて、今の補完が終わった後に続けて読む。
    public func fillFromLatest(maxPages: Int) async throws -> [MastodonNotification]? {
        guard !isFilling else {
            if let newest = newestFillBaseID {
                refillSinceID = refillSinceID.map { Self.older($0, newest) } ?? newest
            }
            return nil
        }
        isFilling = true
        defer { isFilling = false }

        var added: [MastodonNotification] = []
        var next = unfilledSinceID ?? newestFillBaseID
        repeat {
            let sinceID = next
            unfilledSinceID = sinceID
            let fetched: NotificationPage
            let isConnected: Bool
            do {
                (fetched, isConnected) = try await fetchNewer(than: sinceID, maxPages: maxPages)
            } catch {
                if let sinceID, let refillSinceID {
                    unfilledSinceID = Self.older(sinceID, refillSinceID)
                    self.refillSinceID = nil
                }
                throw error
            }
            unfilledSinceID = nil
            if sinceID == nil {
                // 1件もないところへ読んだ最新のページに通知があれば、さらに古い通知があるかもしれない。
                // 満杯かどうかでは判断しない。求めた件数より少なく返すサーバーがあるため。
                reachedEnd = fetched.isEmpty
            }
            if isConnected {
                added += merge(fetched)
            } else if let oldestFetched = fetched.ids.min(by: { StatusID.isNewer($1, than: $0) }) {
                let known = Set(notifications.map(\.id))
                let kept = fetched.notifications.filter { !isDiscarded($0) }
                added += kept.filter { !known.contains($0.id) }
                notifications = Self.sorted(notifications.filter { StatusID.isNewer($0.id, than: oldestFetched) } + kept)
                unreadable = Self.sorted(unreadable.filter { StatusID.isNewer($0.id, than: oldestFetched) } + fetched.unreadable.filter { !resolvedFollowRequestIDs.contains($0.id) }, excluding: notifications)
                reachedEnd = false
                rangeGeneration += 1
            }
            next = refillSinceID
            refillSinceID = nil
        } while next != nil
        return Self.sorted(added)
    }

    /// `sinceID`より新しい通知を、最新の側から最大`maxPages`ページ読む。0件が返ったら、手元とつながっている。
    /// `sinceID`がなければ、手元に通知がないため、最新の1ページだけ読んでつながったものとする。
    ///
    /// 満杯でないページだけでは、つながったと判断しない。求めた件数より少なく返すサーバーでは、その下にも通知が残っているため。
    /// 上限のページを読んだ時点でそのページが満杯でなければ、0件かを確かめるために1回だけ多く読む。
    private func fetchNewer(than sinceID: String?, maxPages: Int) async throws -> (NotificationPage, isConnected: Bool) {
        guard let sinceID else {
            return (try await fetch(TimelineQuery(limit: pageSize)), true)
        }
        var fetched = NotificationPage(notifications: [])
        var maxID: String?
        var remainingPages = max(maxPages, 1)
        var canConfirm = true
        while true {
            let page = try await fetch(TimelineQuery(maxID: maxID, sinceID: sinceID, limit: pageSize))
            guard let oldest = page.ids.min(by: { StatusID.isNewer($1, than: $0) }) else {
                return (fetched, true)
            }
            fetched = NotificationPage(notifications: fetched.notifications + page.notifications, unreadable: fetched.unreadable + page.unreadable)
            maxID = oldest
            remainingPages -= 1
            guard remainingPages == 0 else { continue }
            guard page.count < pageSize, canConfirm else {
                return (fetched, false)
            }
            canConfirm = false
            remainingPages = 1
        }
    }

    // MARK: - ストリーミング

    /// 届いた通知を保留に溜める。保留が空のところへ届いたらtrueを返す。挿入の時機をはかり始める合図にする。
    /// フィルターで出さない投稿についての通知は溜めない。挿入しても一覧が変わらないため。
    public func receive(_ notification: MastodonNotification) -> Bool {
        guard !isDiscarded(notification), !isFilteredOut(notification), !notifications.contains(where: { $0.id == notification.id }), !pending.contains(where: { $0.id == notification.id }) else {
            return false
        }
        pending.append(notification)
        return pending.count == 1
    }

    /// 保留していた通知をIDの順に合流させ、新たに加わった通知を新しい順に返す。
    ///
    /// 読み込んだ末尾より古い通知は捨てる。末尾に足すと、次に古いページを読むときの`max_id`がずれて、間の通知を読み飛ばすため。
    /// 読めなかった通知と同じIDの通知は、末尾にあっても置き換える。並びの位置は変わらないため。
    public func flushPending() -> [MastodonNotification] {
        defer { pending.removeAll() }
        var arrivals = pending
        if !reachedEnd, let oldestID = itemIDs.last {
            let unreadableIDs = Set(unreadable.map(\.id))
            arrivals = arrivals.filter { StatusID.isNewer($0.id, than: oldestID) || unreadableIDs.contains($0.id) }
        }
        return merge(NotificationPage(notifications: arrivals))
    }

    /// 通知の対象の投稿を`transform`で変える。お気に入りなどの操作の結果を反映する。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) -> Bool {
        pending = pending.map { Self.updating(id, in: $0, transform) }
        let replaced = notifications.map { Self.updating(id, in: $0, transform) }
        guard replaced != notifications else { return false }
        notifications = replaced
        return true
    }

    /// 削除された投稿についての通知を除く。サーバーも、投稿を消すとその投稿へのお気に入りなどの通知を消す。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func removeStatus(_ id: Status.ID) -> Bool {
        deletedStatusIDs.insert(id)
        pending.removeAll(where: isDiscarded)
        let remaining = notifications.filter { !isDiscarded($0) }
        guard remaining.count != notifications.count else { return false }
        notifications = remaining
        return true
    }

    /// 承認か却下で片づけたフォローリクエストの通知と、同じユーザーからのほかのフォローリクエストの通知を除く。表示に関わる変化があればtrueを返す。
    /// 片づけた通知は、応答を待つ間に補完で一覧から外れていても、IDを覚えて戻さない。
    @discardableResult
    public func removeFollowRequests(answering request: MastodonNotification) -> Bool {
        let isResolved = { (notification: MastodonNotification) in notification.type == .followRequest && notification.account.id == request.account.id }
        resolvedFollowRequestIDs.insert(request.id)
        resolvedFollowRequestIDs.formUnion((notifications + pending).filter(isResolved).map(\.id))
        pending.removeAll(where: isResolved)
        let remaining = notifications.filter { !isResolved($0) }
        guard remaining.count != notifications.count else { return false }
        notifications = remaining
        return true
    }

    private static func updating(_ id: Status.ID, in notification: MastodonNotification, _ transform: (Status) -> Status) -> MastodonNotification {
        guard let status = notification.status else { return notification }
        let replaced = TimelineStore.updating(id, in: status, transform)
        guard replaced != status else { return notification }
        return MastodonNotification(id: notification.id, type: notification.type, createdAt: notification.createdAt, account: notification.account, status: replaced)
    }

    // MARK: - 未読

    /// 画面に表示された通知を既読にする。既読の位置は新しい方へだけ進む。
    public func markRead(_ ids: some Sequence<String>) {
        let ids = Array(ids)
        lastReadID = Self.advanced(lastReadID, to: ids)
        #if DEBUG
        lastSavableReadID = Self.advanced(lastSavableReadID, to: ids.filter { !debugLocalOnlyIDs.contains($0) })
        #endif
    }

    private static func advanced(_ current: String?, to ids: [String]) -> String? {
        guard let newest = ids.max(by: { StatusID.isNewer($1, than: $0) }) else { return current }
        if let current, !StatusID.isNewer(newest, than: current) { return current }
        return newest
    }

    /// サーバーに保存された既読位置を取り込む。他の端末で読み進めていれば、未読がその分減る。
    public func applySavedMarker(_ id: String) {
        markRead([id])
        markSaved(id)
    }

    #if DEBUG
    /// サーバーにない検証用の通知のID。見れば手元では既読になるが、サーバーに保存する既読位置と、補完の基準には使わない。
    /// 検証用の通知のIDは手元の最新より大きくするため、保存すると本物の通知がそれを追い越すまで未読を数えられず、
    /// 補完の基準にすると、切れていた間に届いた本物の通知を読み落とす。
    public var debugLocalOnlyIDs: Set<String> = []
    /// サーバーに保存できる通知のうち、見た中で最も新しいもののID。
    private var lastSavableReadID: String?
    #endif

    /// 補完の基準にする、手元で最も新しい通知のID。
    private var newestFillBaseID: String? {
        #if DEBUG
        itemIDs.first { !debugLocalOnlyIDs.contains($0) }
        #else
        itemIDs.first
        #endif
    }

    /// サーバーへ保存すべき既読位置。保存済みより進んでいなければnil。
    public var readIDToSave: String? {
        #if DEBUG
        let candidate = lastSavableReadID
        #else
        let candidate = lastReadID
        #endif
        guard let candidate else { return nil }
        if let savedReadID, !StatusID.isNewer(candidate, than: savedReadID) { return nil }
        return candidate
    }

    /// 既読位置をサーバーに保存した。保存済みの位置は新しい方へだけ進む。
    public func markSaved(_ id: String) {
        if let savedReadID, !StatusID.isNewer(id, than: savedReadID) { return }
        savedReadID = id
    }

    /// 既読の位置より新しい、読み込み済みの通知の数。既読の位置が決まっていなければ0。フィルターで出さない通知は数えない。
    public var unreadCount: Int {
        guard let lastReadID else { return 0 }
        let now = Date()
        return notifications.prefix { StatusID.isNewer($0.id, than: lastReadID) }.count { !isFilteredOut($0, now: now) }
    }

    /// 既読の位置より古い通知をまだ読み込んでおらず、未読は`unreadCount`より多いかもしれない。
    public var hasUnloadedUnread: Bool {
        guard let lastReadID, !reachedEnd, let oldestID = itemIDs.last else { return false }
        return StatusID.isNewer(oldestID, than: lastReadID)
    }

    // MARK: - 並べ替え

    /// まだない通知と読めなかった通知を足し、足した通知を新しい順に返す。読めなかった通知と同じIDの通知は、読めなかった行と置き換える。
    /// 削除した投稿についての通知か、片づけたフォローリクエストの通知。
    private func isDiscarded(_ notification: MastodonNotification) -> Bool {
        resolvedFollowRequestIDs.contains(notification.id) || isAboutDeletedStatus(notification)
    }

    private func isAboutDeletedStatus(_ notification: MastodonNotification) -> Bool {
        guard let status = notification.status else { return false }
        return deletedStatusIDs.contains(status.id) || status.reblog.map { deletedStatusIDs.contains($0.id) } ?? false
    }

    /// 足した通知のうち、一覧に並べたものを返す。
    private func merge(_ page: NotificationPage) -> [MastodonNotification] {
        let readIDs = Set(notifications.map(\.id))
        let added = Self.sorted(page.notifications.filter { !readIDs.contains($0.id) && !isDiscarded($0) })
        notifications = Self.sorted(notifications + added)
        let known = Set(itemIDs)
        unreadable = Self.sorted(unreadable + page.unreadable.filter { !known.contains($0.id) && !resolvedFollowRequestIDs.contains($0.id) }, excluding: notifications)
        return added.filter { !isFilteredOut($0) }
    }

    private func isFilteredOut(_ notification: MastodonNotification, now: Date = Date()) -> Bool {
        guard let filtering, let status = notification.status else { return false }
        return filtering.verdict(for: status, now: now).isHidden
    }

    /// IDの新しい順に並べ、同じIDは1つにする。
    private static func sorted(_ notifications: [MastodonNotification]) -> [MastodonNotification] {
        Dictionary(notifications.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            .values
            .sorted { StatusID.isNewer($0.id, than: $1.id) }
    }

    /// IDの新しい順に並べ、同じIDは1つにする。同じIDの通知が読めていれば外す。
    private static func sorted(_ items: [UnreadableItem], excluding notifications: [MastodonNotification]) -> [UnreadableItem] {
        let readIDs = Set(notifications.map(\.id))
        return Dictionary(items.filter { !readIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            .values
            .sorted { StatusID.isNewer($0.id, than: $1.id) }
    }

    private static func older(_ lhs: String, _ rhs: String) -> String {
        StatusID.isNewer(lhs, than: rhs) ? rhs : lhs
    }
}
