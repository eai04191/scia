/// 通知を新しい順に持つ。RESTで読んだページと、ストリーミングで届いた通知を合わせる。
///
/// ホームと違い、ギャップは置かない。通知は上から読むもので、切れていた間に読み切れないほど溜まったら、
/// 古い側を捨てて最新の側から読み直せば足りるため。
@MainActor
public final class NotificationStore {
    public typealias Fetch = @Sendable (TimelineQuery) async throws -> [MastodonNotification]

    /// 新しい順。
    public private(set) var notifications: [MastodonNotification] = []
    /// これより古い通知はない。
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false
    /// ストリーミングで届き、まだ挿入していない通知。届いた順。
    public private(set) var pending: [MastodonNotification] = []
    /// 見た中で最も新しい通知のID。これより新しい通知を未読として数える。
    public private(set) var lastReadID: String?
    /// サーバーのmarkerに保存されている既読位置。
    public private(set) var savedReadID: String?

    /// 補完を始めたが、まだ成功していない基準のID。失敗した後に新着が挿入されて最新のIDが進んでも、次の補完はここから読む。
    private var unfilledSinceID: String?
    private var isFilling = false
    /// 補完の最中に再び補完を求められたときの基準のID。今の補完が終わったら、ここからもう一度読む。
    private var refillSinceID: String?
    /// 補完が古い側を捨てて、読み込む範囲を変えるたびに増やす。変わる前に読み始めた古いページを合流させないために使う。
    private var rangeGeneration = 0
    private let pageSize: Int
    private let fetch: Fetch

    public init(pageSize: Int, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    public var entries: [TimelineEntry] { notifications.map(TimelineEntry.notification) }

    /// 最新のページで置き換える。読み込み中なら何もせずnilを返す。`markerID`を渡すと、そこを既読位置にする。
    public func loadInitial(markerID: String? = nil) async throws -> [MastodonNotification]? {
        guard !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(TimelineQuery(limit: pageSize))
        notifications = Self.sorted(page)
        reachedEnd = page.isEmpty
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
        guard !isLoading, !reachedEnd, let oldest = notifications.last else { return nil }
        isLoading = true
        defer { isLoading = false }

        let generation = rangeGeneration
        let page = try await fetch(TimelineQuery(maxID: oldest.id, limit: pageSize))
        guard generation == rangeGeneration else { return [] }
        if page.isEmpty {
            reachedEnd = true
        }
        return merge(page)
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
            if let newest = notifications.first?.id {
                refillSinceID = refillSinceID.map { Self.older($0, newest) } ?? newest
            }
            return nil
        }
        isFilling = true
        defer { isFilling = false }

        var added: [MastodonNotification] = []
        var next = unfilledSinceID ?? notifications.first?.id
        repeat {
            let sinceID = next
            unfilledSinceID = sinceID
            let fetched: [MastodonNotification]
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
            } else if let oldestFetched = Self.sorted(fetched).last {
                let known = Set(notifications.map(\.id))
                added += fetched.filter { !known.contains($0.id) }
                notifications = Self.sorted(notifications.filter { StatusID.isNewer($0.id, than: oldestFetched.id) } + fetched)
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
    private func fetchNewer(than sinceID: String?, maxPages: Int) async throws -> ([MastodonNotification], isConnected: Bool) {
        guard let sinceID else {
            return (try await fetch(TimelineQuery(limit: pageSize)), true)
        }
        var fetched: [MastodonNotification] = []
        var maxID: String?
        var remainingPages = max(maxPages, 1)
        var canConfirm = true
        while true {
            let page = try await fetch(TimelineQuery(maxID: maxID, sinceID: sinceID, limit: pageSize))
            guard let oldest = Self.sorted(page).last else {
                return (fetched, true)
            }
            fetched += page
            maxID = oldest.id
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
    public func receive(_ notification: MastodonNotification) -> Bool {
        guard !notifications.contains(where: { $0.id == notification.id }), !pending.contains(where: { $0.id == notification.id }) else {
            return false
        }
        pending.append(notification)
        return pending.count == 1
    }

    /// 保留していた通知をIDの順に合流させ、新たに加わった通知を新しい順に返す。
    ///
    /// 読み込んだ末尾より古い通知は捨てる。末尾に足すと、次に古いページを読むときの`max_id`がずれて、間の通知を読み飛ばすため。
    public func flushPending() -> [MastodonNotification] {
        defer { pending.removeAll() }
        var arrivals = pending
        if !reachedEnd, let oldest = notifications.last {
            arrivals = arrivals.filter { StatusID.isNewer($0.id, than: oldest.id) }
        }
        return merge(arrivals)
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

    private static func updating(_ id: Status.ID, in notification: MastodonNotification, _ transform: (Status) -> Status) -> MastodonNotification {
        guard let status = notification.status else { return notification }
        let replaced = TimelineStore.updating(id, in: status, transform)
        guard replaced != status else { return notification }
        return MastodonNotification(id: notification.id, type: notification.type, createdAt: notification.createdAt, account: notification.account, status: replaced)
    }

    // MARK: - 未読

    /// 画面に表示された通知を既読にする。既読の位置は新しい方へだけ進む。
    public func markRead(_ ids: some Sequence<String>) {
        guard let newest = ids.max(by: { StatusID.isNewer($1, than: $0) }) else { return }
        if let lastReadID, !StatusID.isNewer(newest, than: lastReadID) { return }
        lastReadID = newest
    }

    /// サーバーに保存された既読位置を取り込む。他の端末で読み進めていれば、未読がその分減る。
    public func applySavedMarker(_ id: String) {
        markRead([id])
        markSaved(id)
    }

    /// サーバーへ保存すべき既読位置。保存済みより進んでいなければnil。
    public var readIDToSave: String? {
        guard let lastReadID else { return nil }
        if let savedReadID, !StatusID.isNewer(lastReadID, than: savedReadID) { return nil }
        return lastReadID
    }

    /// 既読位置をサーバーに保存した。保存済みの位置は新しい方へだけ進む。
    public func markSaved(_ id: String) {
        if let savedReadID, !StatusID.isNewer(id, than: savedReadID) { return }
        savedReadID = id
    }

    /// 既読の位置より新しい、読み込み済みの通知の数。既読の位置が決まっていなければ0。
    public var unreadCount: Int {
        guard let lastReadID else { return 0 }
        return notifications.prefix { StatusID.isNewer($0.id, than: lastReadID) }.count
    }

    /// 既読の位置より古い通知をまだ読み込んでおらず、未読は`unreadCount`より多いかもしれない。
    public var hasUnloadedUnread: Bool {
        guard let lastReadID, !reachedEnd, let oldest = notifications.last else { return false }
        return StatusID.isNewer(oldest.id, than: lastReadID)
    }

    // MARK: - 並べ替え

    /// まだない通知を足し、足した通知を新しい順に返す。
    private func merge(_ incoming: [MastodonNotification]) -> [MastodonNotification] {
        let known = Set(notifications.map(\.id))
        let added = Self.sorted(incoming.filter { !known.contains($0.id) })
        guard !added.isEmpty else { return [] }
        notifications = Self.sorted(notifications + added)
        return added
    }

    /// IDの新しい順に並べ、同じIDは1つにする。
    private static func sorted(_ notifications: [MastodonNotification]) -> [MastodonNotification] {
        Dictionary(notifications.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            .values
            .sorted { StatusID.isNewer($0.id, than: $1.id) }
    }

    private static func older(_ lhs: String, _ rhs: String) -> String {
        StatusID.isNewer(lhs, than: rhs) ? rhs : lhs
    }
}
