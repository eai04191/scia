import Foundation

/// 通知を新しい順に持つ。RESTで読んだページと、ストリーミングで届いた通知を合わせる。
///
/// サーバーがまとめた通知は、まとまりを1件として持つ。同じまとまりは、`groupKey`で1つにする。
/// ストリーミングで届いた通知は、同じまとまりが手元にあれば、そこへ足して一番上へ移す。
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
    /// 通知を隠すミュートか、ブロックをした相手のアカウントのID。その人からの通知を除き、あとから届いても足さない。
    private var excludedAccountIDs: Set<String> = []
    /// 使う人の操作で一覧から除いた通知のID（承認か却下で片づけたフォローリクエストなど）。サーバーは除いた通知を消すが、その前に読み始めたページで戻さない。
    /// 同じ通知がそのページで読めなかったときも、読めなかった行として戻さない。
    private var removedNotificationIDs: Set<MastodonNotification.ID> = []
    /// 使う人が削除したまとまりのキーと、削除したときのまとまりの最も新しい通知のID、削除した順番（`removalCount`の値）。
    /// 削除より前に読み始めたページでは、IDによらず、まとまりを戻さない。読み始めたあとに届いた通知も、サーバーは削除で消しているため。
    /// ストリーミングで削除した後に届いた通知は、同じキーでも、削除したときのIDより新しければ新しいまとまりとして足す。サーバーは、削除した後の通知を消さないため。
    private var removedGroups: [String: (id: MastodonNotification.ID, order: Int)] = [:]
    /// まとまりを削除した回数。ページを読み始めたときの値と比べ、そのページが削除より前に読み始めたものかを見分ける。
    private var removalCount = 0
    /// ストリーミングで届いて、まとまりへ足した通知。まとまりのキーごとに届いた順。
    /// 補完の応答を待つ間に新着を足すと、手元のまとまりが応答より新しくなる。応答の人数はまだ届いていない分を含むため、手元の値を残すと、その分が欠ける。
    /// 応答の値に、応答より後に届いた分を足し直すのに使う。応答がそれより新しくなったら捨てる。
    private var streamedArrivals: [String: [MastodonNotification]] = [:]
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
    /// まとまりは、読んだ範囲の最も古い通知のIDも含める。続きは、まとまりの中の最も古い通知より古い側から読むため。
    private var itemIDs: [String] {
        (notifications.flatMap { [$0.id, $0.pageMinID] } + unreadable.flatMap { [$0.id] + ($0.pageMinID.map { [$0] } ?? []) })
            .sorted { StatusID.isNewer($0, than: $1) }
    }

    /// 最新のページで置き換える。読み込み中なら何もせずnilを返す。`markerID`を渡すと、そこを既読位置にする。
    public func loadInitial(markerID: String? = nil) async throws -> [MastodonNotification]? {
        guard !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }

        let removals = removalCount
        let page = try await fetch(TimelineQuery(limit: pageSize))
        notifications = Self.sorted(page.notifications.compactMap { admitted($0, fetchedAfter: removals) })
        unreadable = Self.sorted(page.unreadable.filter { !removedNotificationIDs.contains($0.id) }, excluding: notifications)
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
            let removals = removalCount
            let page = try await fetch(TimelineQuery(maxID: maxID, limit: pageSize))
            guard generation == rangeGeneration else { return [] }
            if page.isEmpty {
                reachedEnd = true
            }
            let added = merge(page, fetchedAfter: removals)
            // 削除済みの投稿についての通知や、ミュートかブロックした相手の通知しかなかったときは、一覧に残らないため、ページの一番古い通知の先へ進む。
            // それでも続きを読む位置が進まなければ、同じページを読み続けないよう止める。
            let pageOldestID = page.ids.reduce(itemIDs.last) { oldest, id in oldest.map { Self.older($0, id) } ?? id }
            guard added.isEmpty, !page.isEmpty, page.unreadable.isEmpty, let next = pageOldestID, next != maxID else {
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
    ///
    /// - Parameter progress: 1ページ読むたびに、この補完で読んだ通知の数を渡す。手元の通知と重なる分も数える。
    ///   新たに加わる通知は、つながったかが分かるまで並べないため。補完の最中に呼ばれてnilを返すときは呼ばない。
    public func fillFromLatest(maxPages: Int, progress: ((Int) -> Void)? = nil) async throws -> [MastodonNotification]? {
        guard !isFilling else {
            if let newest = newestFillBaseID {
                refillSinceID = refillSinceID.map { Self.older($0, newest) } ?? newest
            }
            return nil
        }
        isFilling = true
        defer { isFilling = false }

        var added: [MastodonNotification] = []
        var readCount = 0
        var next = unfilledSinceID ?? newestFillBaseID
        repeat {
            let sinceID = next
            unfilledSinceID = sinceID
            let fetched: NotificationPage
            let isConnected: Bool
            let readBefore = readCount
            let removals = removalCount
            do {
                (fetched, isConnected) = try await fetchNewer(than: sinceID, maxPages: maxPages) { count in
                    readCount = readBefore + count
                    progress?(readCount)
                }
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
                added += merge(fetched, fetchedAfter: removals)
            } else if let oldestFetched = fetched.ids.min(by: { StatusID.isNewer($1, than: $0) }) {
                let known = Dictionary(notifications.map { ($0.groupKey, $0.id) }, uniquingKeysWith: { first, _ in first })
                let (kept, replayedKeys) = replayingArrivals(onto: fetched.notifications.compactMap { admitted($0, fetchedAfter: removals) }, keepsLocalPage: false)
                added += kept.filter { notification in known[notification.groupKey].map { StatusID.isNewer(notification.id, than: $0) } ?? true }
                // 残す手元の行は、捨てた範囲の続きの位置を引き継がない。引き継ぐと、続きの読み込みがまだ読んでいない範囲を飛び越える。
                let local = notifications
                    .filter { StatusID.isNewer($0.id, than: oldestFetched) && !replayedKeys.contains($0.groupKey) }
                    .map { $0.clampingPage(notOlderThan: oldestFetched) }
                notifications = Self.sorted(kept + local)
                unreadable = Self.sorted(unreadable.filter { StatusID.isNewer($0.id, than: oldestFetched) } + fetched.unreadable.filter { !removedNotificationIDs.contains($0.id) }, excluding: notifications)
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
    /// - Parameter progress: 1ページ読むたびに、ここで読んだ通知の数を渡す。
    private func fetchNewer(than sinceID: String?, maxPages: Int, progress: (Int) -> Void) async throws -> (NotificationPage, isConnected: Bool) {
        guard let sinceID else {
            let page = try await fetch(TimelineQuery(limit: pageSize))
            progress(page.count)
            return (page, true)
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
            progress(fetched.count)
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

    /// 保留していた通知をIDの順に合流させ、新たに加わったか一番上へ移った通知を新しい順に返す。
    ///
    /// まとめる種類の通知は、同じまとまりが手元にあれば、そこへ足して一番上へ移す。すでに並べている人の通知は足さず、移さない。
    /// 読み込んだ末尾より古い通知は捨てる。末尾に足すと、次に古いページを読むときの`max_id`がずれて、間の通知を読み飛ばすため。
    /// 読めなかった通知と同じIDの通知は、末尾にあっても置き換える。並びの位置は変わらないため。
    public func flushPending() -> [MastodonNotification] {
        defer { pending.removeAll() }
        var arrivals = pending.sorted { StatusID.isNewer($1.id, than: $0.id) }
        if !reachedEnd, let oldestID = itemIDs.last {
            let unreadableIDs = Set(unreadable.map(\.id))
            arrivals = arrivals.filter { StatusID.isNewer($0.id, than: oldestID) || unreadableIDs.contains($0.id) }
        }
        var current = Dictionary(notifications.map { ($0.groupKey, $0) }, uniquingKeysWith: { first, _ in first })
        let knownIDs = Set(notifications.map(\.id))
        var changed: [String: MastodonNotification] = [:]
        for arrival in arrivals.compactMap({ admitted($0) }) where !knownIDs.contains(arrival.id) {
            if let existing = current[arrival.groupKey] {
                // まとまりの最も新しい通知より古い通知は、補完で読んだまとまりにもう数えられている。
                guard StatusID.isNewer(arrival.id, than: existing.id), let grown = existing.adding(arrival) else { continue }
                current[arrival.groupKey] = grown
                changed[arrival.groupKey] = grown
            } else {
                current[arrival.groupKey] = arrival
                changed[arrival.groupKey] = arrival
            }
            if arrival.type.isGrouped {
                streamedArrivals[arrival.groupKey, default: []].append(arrival)
            }
        }
        notifications = Self.sorted(Array(current.values))
        unreadable = Self.sorted(unreadable, excluding: notifications)
        // 一覧から外れたまとまりの分は、足し直す先がないので捨てる。
        streamedArrivals = streamedArrivals.filter { current[$0.key] != nil }
        return Self.sorted(Array(changed.values)).filter { !isFilteredOut($0) }
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
        return readmit()
    }

    /// 通知を隠すミュートか、ブロックをした相手からの通知を除く。あとから届いても足さない。表示に関わる変化があればtrueを返す。
    /// まとまりからは、その人だけを外す。ほかの人が残れば、まとまりは残る。
    @discardableResult
    public func excludeAccount(_ id: String) -> Bool {
        excludedAccountIDs.insert(id)
        return readmit()
    }

    /// 保留と手元の通知を、除く決まりに当て直す。表示に関わる変化があればtrueを返す。
    private func readmit() -> Bool {
        pending.removeAll(where: isDiscarded)
        let remaining = notifications.compactMap { admitted($0) }
        guard remaining != notifications else { return false }
        notifications = remaining
        return true
    }

    /// ミュートやブロックを解除した相手からの通知を、また足すようにする。除いた通知は戻さず、読み込み直したときに戻る。
    public func includeAccount(_ id: String) {
        excludedAccountIDs.remove(id)
    }

    /// 承認か却下で片づけたフォローリクエストの通知と、同じユーザーからのほかのフォローリクエストの通知を除く。表示に関わる変化があればtrueを返す。
    /// 片づけた通知は、応答を待つ間に補完で一覧から外れていても、IDを覚えて戻さない。
    @discardableResult
    public func removeFollowRequests(answering request: MastodonNotification) -> Bool {
        let isResolved = { (notification: MastodonNotification) in notification.type == .followRequest && notification.account.id == request.account.id }
        removedNotificationIDs.insert(request.id)
        removedNotificationIDs.formUnion((notifications + pending).filter(isResolved).map(\.id))
        pending.removeAll(where: isResolved)
        let remaining = notifications.filter { !isResolved($0) }
        guard remaining.count != notifications.count else { return false }
        notifications = remaining
        return true
    }

    /// 使う人が削除した通知を除く。表示に関わる変化があればtrueを返す。
    /// 削除した通知は、応答を待つ間に補完で一覧から外れていても、IDを覚えて戻さない。
    /// 応答を待つ間に読んだページで、同じ通知が読めなかった行として入っていれば、それも除く。
    /// - Parameter groupKey: 削除したまとまりのキー。メニューを開いてから応答が届くまでに新着が足されて、まとまりのIDが変わっていても、キーで除く。
    @discardableResult
    public func removeNotification(_ id: MastodonNotification.ID, groupKey: String? = nil) -> Bool {
        removedNotificationIDs.insert(id)
        let key = groupKey ?? notifications.first(where: { $0.id == id })?.groupKey
        if let key {
            let newestID = notifications.first { $0.groupKey == key }.map { StatusID.isNewer($0.id, than: id) ? $0.id : id } ?? id
            removalCount += 1
            removedGroups[key] = (newestID, removalCount)
        }
        pending.removeAll { $0.id == id || ($0.groupKey == key && key != nil) }
        if let key {
            streamedArrivals[key] = nil
        }
        let remaining = notifications.filter { $0.id != id && $0.groupKey != key }
        let remainingUnreadable = unreadable.filter { $0.id != id }
        guard remaining.count != notifications.count || remainingUnreadable.count != unreadable.count else { return false }
        notifications = remaining
        unreadable = remainingUnreadable
        return true
    }

    private static func updating(_ id: Status.ID, in notification: MastodonNotification, _ transform: (Status) -> Status) -> MastodonNotification {
        guard let status = notification.status else { return notification }
        let replaced = TimelineStore.updating(id, in: status, transform)
        guard replaced != status else { return notification }
        return notification.replacing(status: replaced)
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

    /// 削除した投稿についての通知か、片づけたフォローリクエストか、削除した通知か、除いた人だけの通知。
    private func isDiscarded(_ notification: MastodonNotification) -> Bool {
        admitted(notification) == nil
    }

    /// 一覧に入れる形にする。除く通知ならnil。まとまりからは、除いた人だけを外す。
    /// - Parameter removals: ページから読んだ通知なら、ページを読み始めたときの`removalCount`。それより後に削除したまとまりは、IDによらず戻さない。
    private func admitted(_ notification: MastodonNotification, fetchedAfter removals: Int? = nil) -> MastodonNotification? {
        guard !removedNotificationIDs.contains(notification.id), !isAboutDeletedStatus(notification) else { return nil }
        if let removed = removedGroups[notification.groupKey] {
            if let removals, removed.order > removals { return nil }
            if !StatusID.isNewer(notification.id, than: removed.id) { return nil }
        }
        return notification.removingAccounts(excludedAccountIDs)
    }

    private func isAboutDeletedStatus(_ notification: MastodonNotification) -> Bool {
        guard let status = notification.status else { return false }
        return deletedStatusIDs.contains(status.id) || status.reblog.map { deletedStatusIDs.contains($0.id) } ?? false
    }

    /// まだない通知と読めなかった通知を足し、足した通知のうち一覧に並べたものを新しい順に返す。読めなかった通知と同じIDの通知は、読めなかった行と置き換える。
    /// 手元と同じまとまりは、最も新しい通知が新しいほうの値を使い、新しくなったものを足した通知として返す。
    /// サーバーは、読んだ範囲の上限より古い、そのまとまりの通知を全部数えて返すため、新しいほうの値が古いほうを含む。
    /// - Parameter removals: ページを読み始めたときの`removalCount`。
    private func merge(_ page: NotificationPage, fetchedAfter removals: Int) -> [MastodonNotification] {
        let known = Dictionary(notifications.map { ($0.groupKey, $0.id) }, uniquingKeysWith: { first, _ in first })
        let (incoming, replayedKeys) = replayingArrivals(onto: page.notifications.compactMap { admitted($0, fetchedAfter: removals) }, keepsLocalPage: true)
        let added = Self.sorted(incoming.filter { notification in known[notification.groupKey].map { StatusID.isNewer(notification.id, than: $0) } ?? true })
        // 同じIDなら、手元を残す。操作の結果を反映した手元の投稿を、読み始めたときのページで戻さないため。
        notifications = Self.sorted(incoming + notifications.filter { !replayedKeys.contains($0.groupKey) })
        let knownIDs = Set(itemIDs)
        unreadable = Self.sorted(unreadable + page.unreadable.filter { !knownIDs.contains($0.id) && !removedNotificationIDs.contains($0.id) }, excluding: notifications)
        return added.filter { !isFilteredOut($0) }
    }

    /// ページで読んだまとまりのうち、手元のほうが新しいもの（応答を待つ間にストリーミングで新着を足した）に、応答より後に届いた通知を足し直す。
    /// 足し直したまとまりは手元の行の位置（最も新しい通知）と投稿を引き継ぐので、行は動かない。足し直したまとまりのキーも返す。
    /// 応答より新しい通知が手元に届いていないキーは、覚えておく必要がないので捨てる。
    /// - Parameter keepsLocalPage: 手元の続きの位置を引き継ぐ。補完が古い側を捨てて読み直すときは引き継がない。
    private func replayingArrivals(onto incoming: [MastodonNotification], keepsLocalPage: Bool) -> ([MastodonNotification], Set<String>) {
        let local = Dictionary(notifications.map { ($0.groupKey, $0) }, uniquingKeysWith: { first, _ in first })
        var replayedKeys: Set<String> = []
        let result = incoming.map { snapshot -> MastodonNotification in
            let later = streamedArrivals[snapshot.groupKey]?.filter { StatusID.isNewer($0.id, than: snapshot.id) } ?? []
            streamedArrivals[snapshot.groupKey] = later.isEmpty ? nil : later
            guard let current = local[snapshot.groupKey], StatusID.isNewer(current.id, than: snapshot.id), !later.isEmpty else { return snapshot }
            replayedKeys.insert(snapshot.groupKey)
            let grown = later.reduce(snapshot) { $0.adding($1) ?? $0 }
            let page = keepsLocalPage && StatusID.isNewer(grown.pageMinID, than: current.pageMinID) ? current.pageMinID : grown.pageMinID
            return MastodonNotification(
                id: current.id, type: grown.type, createdAt: current.createdAt, account: grown.account, status: current.status, groupKey: grown.groupKey,
                notificationsCount: grown.notificationsCount, sampleAccounts: grown.sampleAccounts, pageMinID: page
            )
        }
        return (result, replayedKeys)
    }

    private func isFilteredOut(_ notification: MastodonNotification, now: Date = Date()) -> Bool {
        guard let filtering, let status = notification.status else { return false }
        return filtering.verdict(for: status, now: now).isHidden
    }

    /// IDの新しい順に並べ、同じまとまりは1つにする。最も新しい通知が新しいほうを残し、同じなら後ろのほうを残す。
    /// 続きを読む位置は、どちらか古いほうにする。
    private static func sorted(_ notifications: [MastodonNotification]) -> [MastodonNotification] {
        Dictionary(notifications.map { ($0.groupKey, $0) }, uniquingKeysWith: { old, new in
            StatusID.isNewer(old.id, than: new.id) ? old.extendingPage(to: new.pageMinID) : new.extendingPage(to: old.pageMinID)
        })
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
