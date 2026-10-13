/// タイムラインの投稿を新しい順に持つ。RESTで読んだページと、ストリーミングで届いたイベントを合わせる。
///
/// 投稿はIDの順に並べる。RESTのページングがIDを境に読むため、表示の順もIDに揃えておくと、境目で読み飛ばしや重複が起きない。
@MainActor
public final class TimelineStore {
    public typealias Fetch = @Sendable (TimelineQuery) async throws -> TimelinePage

    /// 新しい順。
    public private(set) var entries: [TimelineEntry] = []
    /// これより古い投稿はない。
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false
    /// 直近の読み込みで、サーバーがホームを再生成中だった。結果が揃っていないため、時間をおいて読み直す。
    public private(set) var isRegenerating = false
    /// ストリーミングで届き、まだ挿入していない投稿。届いた順。
    public private(set) var pending: [Status] = []
    /// 見た中で最も新しい投稿のID。これより新しい投稿を未読として数える。
    public private(set) var lastReadID: String?
    /// サーバーのmarkerに保存されている既読位置。
    public private(set) var savedReadID: String?
    /// 読み込み中のギャップのID。
    public private(set) var loadingGapIDs: Set<String> = []

    /// 補完を始めたが、まだ成功していない基準のID。失敗した後に新着が挿入されて最新のIDが進んでも、次の補完はここから読む。
    private var unfilledSinceID: String?
    private var isFilling = false
    /// 補完の最中に再び補完を求められたときの基準のID。今の補完が終わったら、ここからもう一度読む。
    private var refillSinceID: String?
    /// 削除のイベントで消した投稿のID。削除の前に読み始めたRESTの結果に含まれていても、表示に戻さない。
    private var deletedIDs: Set<String> = []
    private let pageSize: Int
    private let fetch: Fetch

    public init(pageSize: Int, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    /// 新しい順。
    public var statuses: [Status] { entries.compactMap(\.status) }

    public var gaps: [TimelineGap] {
        entries.compactMap { entry in
            if case .gap(let gap) = entry { gap } else { nil }
        }
    }

    /// 最新のページで置き換える。読み込み中なら何もせずnilを返す。
    ///
    /// `markerID`（サーバーに保存された既読位置）を渡すと、そこを既読位置にする。最新のページより古ければ、
    /// 既読位置のすぐ後に続く投稿と、既読位置から古い投稿も読み、最新のページとの間が埋まらなければギャップを置く。
    /// 既読位置から続きを読めるようにするため。
    public func loadInitial(around markerID: String? = nil) async throws -> [Status]? {
        guard !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }

        let latest = try await fetch(TimelineQuery(limit: pageSize))
        var loaded = latest.statuses
        var loadedGaps: [TimelineGap] = []
        if let markerID, !latest.isRegenerating, let oldestLatest = Self.oldest(of: latest.statuses), StatusID.isNewer(oldestLatest.id, than: markerID) {
            let afterMarker = try await fetch(TimelineQuery(minID: markerID, limit: pageSize))
            let fromMarker = try await fetch(TimelineQuery(maxID: Self.oldest(of: afterMarker.statuses)?.id ?? oldestLatest.id, limit: pageSize))
            loaded += afterMarker.statuses + fromMarker.statuses
            if afterMarker.statuses.count >= pageSize,
               let newestAfterMarker = Self.newest(of: afterMarker.statuses),
               StatusID.isNewer(oldestLatest.id, than: newestAfterMarker.id) {
                loadedGaps.append(TimelineGap(newerID: oldestLatest.id, olderID: newestAfterMarker.id))
            }
        }
        let unique = Dictionary(loaded.filter { !isDeleted($0) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rebuild(statuses: Array(unique.values), gaps: loadedGaps)
        isRegenerating = latest.isRegenerating
        reachedEnd = latest.statuses.isEmpty && !latest.isRegenerating
        if let markerID {
            applySavedMarker(markerID)
        }
        return statuses
    }

    /// 末尾より古いページを読み、新たに足した投稿を返す。
    /// 読み込み中、終端に達している、まだ1件もない場合は何もせずnilを返す。
    public func loadOlder() async throws -> [Status]? {
        guard !isLoading, !reachedEnd, let oldest = statuses.last else { return nil }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(TimelineQuery(maxID: oldest.id, limit: pageSize))
        isRegenerating = page.isRegenerating
        let added = merge(page.statuses)
        if page.statuses.isEmpty && !page.isRegenerating {
            reachedEnd = true
        }
        return added
    }

    // MARK: - 切れていた間の補完

    /// ストリーミングが切れていた間の投稿を読み、新たに加わった投稿を新しい順に返す。まだ1件もなければ何もせずnilを返す。
    ///
    /// 読み込んだ中で最も新しい投稿より新しいものを、最新の側から1ページ読む。1ページに収まらなければ、残りをギャップとして置く。
    /// 接続し直した後に呼ぶ。その間に届いた新着が先に挿入されていても、基準のIDは読み始める前に決めるため、間を読み飛ばさない。
    /// 失敗したとき、またはサーバーがホームを再生成中で結果が揃っていないときは、次の呼び出しも同じ基準から読む。
    ///
    /// 補完の最中に呼ばれたら、そのときの基準を覚えてnilを返し、今の補完が終わった後に続けて読む。
    /// 同じ基準で並行して読むと、同じギャップが2つできるため。
    public func fillFromLatest() async throws -> [Status]? {
        guard !isFilling else {
            if let newest = statuses.first?.id {
                refillSinceID = refillSinceID.map { Self.older($0, newest) } ?? newest
            }
            return nil
        }
        isFilling = true
        defer { isFilling = false }

        var added: [Status] = []
        var next = unfilledSinceID ?? statuses.first?.id
        while let sinceID = next {
            unfilledSinceID = sinceID
            let page: TimelinePage
            do {
                page = try await fetch(TimelineQuery(sinceID: sinceID, limit: pageSize))
            } catch {
                if let refillSinceID {
                    unfilledSinceID = Self.older(sinceID, refillSinceID)
                    self.refillSinceID = nil
                }
                throw error
            }
            if !page.isRegenerating {
                unfilledSinceID = nil
            }
            added += merge(page.statuses)
            if page.statuses.count >= pageSize, let oldestFetched = Self.oldest(of: page.statuses) {
                rebuild(statuses: statuses, gaps: gaps + [TimelineGap(newerID: oldestFetched.id, olderID: sinceID)])
            }
            next = refillSinceID
            refillSinceID = nil
        }
        return added.sorted { StatusID.isNewer($0.id, than: $1.id) }
    }

    /// ギャップをどちらの端から読むか。
    public enum GapDirection: Sendable {
        /// 新しい側の端から古い方へ。上から読み進めてギャップに着いたときに使う。
        case fromNewer
        /// 古い側の端から新しい方へ。下から遡ってギャップに着いたときに使う。
        case fromOlder
    }

    /// ギャップを1ページ分読み、新たに加わった投稿を新しい順に返す。読み切れなかった分はギャップとして残す。
    /// そのギャップがない、または読み込み中なら何もせずnilを返す。
    public func loadGap(_ id: String, from direction: GapDirection) async throws -> [Status]? {
        guard let gap = gaps.first(where: { $0.id == id }), !loadingGapIDs.contains(id) else { return nil }
        loadingGapIDs.insert(id)
        defer { loadingGapIDs.remove(id) }

        let query = switch direction {
        case .fromNewer: TimelineQuery(maxID: gap.newerID, sinceID: gap.olderID, limit: pageSize)
        case .fromOlder: TimelineQuery(maxID: gap.newerID, minID: gap.olderID, limit: pageSize)
        }
        let page = try await fetch(query)
        let added = merge(page.statuses)
        // 読んでいる間に削除などで並びが変わっていても、ギャップはIDで探し直す。
        var remaining = gaps
        guard let index = remaining.firstIndex(where: { $0.id == id }) else { return added }
        if page.statuses.count < pageSize, !page.isRegenerating {
            remaining.remove(at: index)
        } else if !page.statuses.isEmpty {
            // 満杯のページなら続きがある。再生成中の短いページは結果が揃っていない。どちらも読めた分だけ縮めてギャップを残す。
            switch direction {
            case .fromNewer:
                if let oldestFetched = Self.oldest(of: page.statuses) {
                    remaining[index] = remaining[index].narrowed(newerID: oldestFetched.id)
                }
            case .fromOlder:
                if let newestFetched = Self.newest(of: page.statuses) {
                    remaining[index] = remaining[index].narrowed(olderID: newestFetched.id)
                }
            }
        }
        rebuild(statuses: statuses, gaps: remaining)
        return added
    }

    // MARK: - ストリーミング

    /// イベントを反映した結果。
    public enum EventResult: Equatable, Sendable {
        /// 表示に関わる変化はない。
        case none
        /// 保留が空のところへ新着が届いた。挿入の時機をはかり始める。
        case pendingStarted
        /// `entries`が変わった。
        case entriesChanged
    }

    /// 新着は保留に溜め、編集と削除はすぐ反映する。
    public func receive(_ event: StreamingEvent) -> EventResult {
        switch event {
        case .update(let status):
            guard !statuses.contains(where: { $0.id == status.id }), !pending.contains(where: { $0.id == status.id }) else {
                return .none
            }
            pending.append(status)
            return pending.count == 1 ? .pendingStarted : .none
        case .statusUpdate(let edited):
            pending = pending.map { Self.replacing(edited, in: $0) }
            let replaced = entries.map { entry -> TimelineEntry in
                guard case .status(let status) = entry else { return entry }
                return .status(Self.replacing(edited, in: status))
            }
            guard replaced != entries else { return .none }
            entries = replaced
            return .entriesChanged
        case .delete(let id):
            deletedIDs.insert(id)
            // 元の投稿が消えると、それをブーストした投稿も表示できなくなる。
            pending.removeAll { $0.id == id || $0.reblog?.id == id }
            let remaining = entries.filter { entry in
                guard case .status(let status) = entry else { return true }
                return status.id != id && status.reblog?.id != id
            }
            guard remaining.count != entries.count else { return .none }
            entries = remaining
            return .entriesChanged
        case .filtersChanged, .unhandled:
            return .none
        }
    }

    /// 保留していた投稿をIDの順に合流させ、新たに加わった投稿を新しい順に返す。
    ///
    /// 読み込んだ末尾より古い投稿は捨てる。末尾に足すと、次に古いページを読むときの`max_id`がずれて、間の投稿を読み飛ばすため。
    public func flushPending() -> [Status] {
        defer { pending.removeAll() }
        var arrivals = pending
        if !reachedEnd, let oldest = statuses.last {
            arrivals = arrivals.filter { StatusID.isNewer($0.id, than: oldest.id) }
        }
        return merge(arrivals)
    }

    // MARK: - 未読

    /// 画面に表示された投稿を既読にする。既読の位置は新しい方へだけ進む。
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

    #if DEBUG
    /// サーバーにない検証用の投稿のID。見れば手元では既読になるが、サーバーに保存する既読位置には使わない。
    /// 保存すると、本物の投稿がそれを追い越すまで、前回の既読位置から読み始められなくなるため。
    public var debugLocalOnlyIDs: Set<String> = []
    /// サーバーに保存できる投稿のうち、見た中で最も新しいもののID。
    private var lastSavableReadID: String?
    #endif

    /// サーバーに保存された既読位置を取り込む。他の端末で読み進めていれば、未読がその分減る。
    public func applySavedMarker(_ id: String) {
        markRead([id])
        markSaved(id)
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

    /// 既読の位置より新しい、読み込み済みの投稿の数。既読の位置が決まっていなければ0。
    public var unreadCount: Int {
        guard let lastReadID else { return 0 }
        return statuses.prefix { StatusID.isNewer($0.id, than: lastReadID) }.count
    }

    /// 既読の位置より新しい区間にギャップがあり、未読は`unreadCount`より多い。
    public var hasUnloadedUnread: Bool {
        guard let lastReadID else { return false }
        return gaps.contains { !StatusID.isNewer(lastReadID, than: $0.olderID) }
    }

    #if DEBUG
    /// 新しい方から`count`件の投稿と、その間のギャップを忘れる。切断している間に投稿を取りこぼした状態を、実データで再現する検証用。
    public func debugForgetNewest(_ count: Int) {
        let remaining = Array(statuses.dropFirst(count))
        let newestKept = remaining.first?.id
        // 新しい側の端の投稿を忘れたギャップは、補完で読み直す範囲に含まれるので消す。
        rebuild(statuses: remaining, gaps: gaps.filter { gap in newestKept.map { !StatusID.isNewer(gap.newerID, than: $0) } ?? false })
    }
    #endif

    // MARK: - 並べ替え

    /// まだない投稿を足し、足した投稿を新しい順に返す。
    private func merge(_ incoming: [Status]) -> [Status] {
        let known = Set(statuses.map(\.id))
        let added = Dictionary(incoming.filter { !known.contains($0.id) && !isDeleted($0) }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            .values
            .sorted { StatusID.isNewer($0.id, than: $1.id) }
        guard !added.isEmpty else { return [] }
        rebuild(statuses: statuses + added, gaps: gaps)
        return added
    }

    /// 投稿をIDの新しい順に並べ、ギャップを新しい側の端の投稿のすぐ下に置く。
    /// 画面は要素をIDで区別するため、同じIDのギャップは1つにする。同じ基準で補完が重なると、同じ範囲のギャップができる。
    private func rebuild(statuses: [Status], gaps: [TimelineGap]) {
        let sortedStatuses = statuses.sorted { StatusID.isNewer($0.id, than: $1.id) }
        var seenGapIDs: Set<String> = []
        let sortedGaps = gaps
            .filter { seenGapIDs.insert($0.id).inserted }
            .sorted { StatusID.isNewer($0.newerID, than: $1.newerID) }
        var result: [TimelineEntry] = []
        result.reserveCapacity(sortedStatuses.count + sortedGaps.count)
        var gapIndex = sortedGaps.startIndex
        for status in sortedStatuses {
            while gapIndex < sortedGaps.endIndex, StatusID.isNewer(sortedGaps[gapIndex].newerID, than: status.id) {
                result.append(.gap(sortedGaps[gapIndex]))
                gapIndex += 1
            }
            result.append(.status(status))
        }
        result.append(contentsOf: sortedGaps[gapIndex...].map(TimelineEntry.gap))
        entries = result
    }

    private func isDeleted(_ status: Status) -> Bool {
        deletedIDs.contains(status.id) || status.reblog.map { deletedIDs.contains($0.id) } ?? false
    }

    private static func older(_ lhs: String, _ rhs: String) -> String {
        StatusID.isNewer(lhs, than: rhs) ? rhs : lhs
    }

    private static func newest(of statuses: [Status]) -> Status? {
        statuses.max { StatusID.isNewer($1.id, than: $0.id) }
    }

    private static func oldest(of statuses: [Status]) -> Status? {
        statuses.min { StatusID.isNewer($1.id, than: $0.id) }
    }

    private static func replacing(_ edited: Status, in status: Status) -> Status {
        if status.id == edited.id { return edited }
        if status.reblog?.id == edited.id { return status.replacingReblog(with: edited) }
        return status
    }
}
