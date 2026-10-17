import Foundation
import os

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
    /// 直近の読み込みに失敗したギャップと、その理由。読み直し始めたら外す。
    private var failedGaps: [String: ErrorPresentation] = [:]

    /// 補完を始めたが、まだ成功していない基準のID。失敗した後に新着が挿入されて最新のIDが進んでも、次の補完はここから読む。
    private var unfilledSinceID: String?
    private var isFilling = false
    /// 補完の最中に再び補完を求められたときの基準のID。今の補完が終わったら、ここからもう一度読む。
    private var refillSinceID: String?
    /// 削除のイベントで消した投稿のID。削除の前に読み始めたRESTの結果に含まれていても、表示に戻さない。
    private var deletedIDs: Set<String> = []
    /// 読めなかった投稿。同じIDの投稿が読めたら外す。
    private var unreadableItems: [UnreadableItem] = []
    private let pageSize: Int
    private let fetch: Fetch
    private let logger = SciaLog.logger(category: "timeline")

    public init(pageSize: Int, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    /// 新しい順。
    public var statuses: [Status] { entries.compactMap(\.status) }

    /// 読めた投稿も読めなかった投稿もない。読めなかった投稿しかなくても、続きは読めるため空ではない。
    public var isEmpty: Bool { itemIDs.isEmpty }

    /// 読めた投稿と読めなかった投稿のID。新しい順。続きを読む位置に使う。
    /// 読めなかった投稿も含めるのは、1ページの全部が読めなかったときにも、その先へ進めるようにするため。
    private var itemIDs: [String] {
        entries.compactMap { entry in
            switch entry {
            case .status(let status): status.id
            case .unreadable(let item): item.id
            case .gap, .notification, .pinned: nil
            }
        }
    }

    public var gaps: [TimelineGap] {
        entries.compactMap { entry in
            if case .gap(let gap) = entry { gap } else { nil }
        }
    }

    /// 直近の読み込みに失敗したギャップと、その理由。行の中で読めなかったことを知らせるのに使う。閉じたギャップは含めない。
    public var gapFailures: [String: ErrorPresentation] {
        let ids = Set(gaps.map(\.id))
        return failedGaps.filter { ids.contains($0.key) }
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
        var loaded = [latest]
        var loadedGaps: [TimelineGap] = []
        if let markerID, !latest.isRegenerating, let oldestLatest = Self.oldestID(of: latest), StatusID.isNewer(oldestLatest, than: markerID) {
            let afterMarker = try await fetch(TimelineQuery(minID: markerID, limit: pageSize))
            let fromMarker = try await fetch(TimelineQuery(maxID: Self.oldestID(of: afterMarker) ?? oldestLatest, limit: pageSize))
            loaded += [afterMarker, fromMarker]
            // 件数では判断しない。求めた件数より少なく返すサーバーでは、満杯でなくても間に投稿が残っているため。
            // 間に投稿がなかったときは、ギャップを読んだときに0件が返って閉じる。
            if let newestAfterMarker = Self.newestID(of: afterMarker),
               StatusID.isNewer(oldestLatest, than: newestAfterMarker) {
                loadedGaps.append(TimelineGap(newerID: oldestLatest, olderID: newestAfterMarker))
            }
        }
        let unique = Dictionary(loaded.flatMap(\.statuses).filter { !isDeleted($0) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        unreadableItems = Self.unique(loaded.flatMap(\.unreadable).filter { !deletedIDs.contains($0.id) })
        rebuild(statuses: Array(unique.values), gaps: loadedGaps)
        // 前の一覧で埋まらなかった基準は、読み直した一覧の範囲の外にあり、そこから読むと読み込み済みの区間にギャップを置いてしまう。
        unfilledSinceID = nil
        isRegenerating = latest.isRegenerating
        reachedEnd = latest.isEmpty && !latest.isRegenerating
        if let markerID {
            applySavedMarker(markerID)
        }
        return statuses
    }

    /// 末尾より古いページを読み、新たに足した投稿を返す。
    /// 読み込み中、終端に達している、まだ1件もない場合は何もせずnilを返す。
    public func loadOlder() async throws -> [Status]? {
        guard !isLoading, !reachedEnd, let oldestID = itemIDs.last else { return nil }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(TimelineQuery(maxID: oldestID, limit: pageSize))
        isRegenerating = page.isRegenerating
        let added = merge(page)
        if page.isEmpty && !page.isRegenerating {
            reachedEnd = true
        }
        return added
    }

    // MARK: - 切れていた間の補完

    /// ストリーミングが切れていた間の投稿を読み、新たに加わった投稿を新しい順に返す。
    /// まだ1件もなければ最新のページを読む。ストリーミングにつながらないサーバーでは、ポーリングの補完だけが空のホームに新着を届けるため。
    ///
    /// 読み込んだ中で最も新しい投稿より新しいものを、最新の側から1ページ読む。読めた投稿と手元の投稿の間にはギャップを置き、
    /// 0件が返るまで読み切ったとは判断しない。求めた件数より少なく返すサーバーでは、満杯でないページの下にも投稿が残っているため。
    /// 接続し直した後に呼ぶ。その間に届いた新着が先に挿入されていても、基準のIDは読み始める前に決めるため、間を読み飛ばさない。
    /// 失敗したとき、またはサーバーがホームを再生成中で結果が揃っていないときは、次の呼び出しも同じ基準から読む。
    /// 再生成中でも投稿が返ったら、返った中で最も新しい投稿から下をギャップにし、次の呼び出しはその投稿から読む。
    ///
    /// 補完の最中に呼ばれたら、そのときの基準を覚えてnilを返し、今の補完が終わった後に続けて読む。
    /// 同じ基準で並行して読むと、同じギャップが2つできるため。続けて読むときは、今の補完で読み終えた範囲より新しいところから読む。
    /// 今の補完が再生成中で読めなかったら、読めなかった基準から読み直す。
    ///
    /// 満杯のページなら、手元の投稿とつながるまで`maxPages`ページまで続けて読み、ギャップを残さないようにする。
    /// 満杯でないページなら、`maxPages`によらずギャップを1回は読み、間が空なのを確かめて閉じる。
    /// 2ページ目以降の読み込みに失敗したら、そこで止めて残りをギャップとして残す。1ページ目の結果はもう反映しているため。
    public func fillFromLatest(maxPages: Int = 1) async throws -> [Status]? {
        guard !isFilling else {
            if let newest = itemIDs.first {
                refillSinceID = refillSinceID.map { Self.older($0, newest) } ?? newest
            }
            return nil
        }
        isFilling = true
        defer { isFilling = false }

        guard let firstSinceID = unfilledSinceID ?? itemIDs.first else {
            let page = try await fetch(TimelineQuery(limit: pageSize))
            isRegenerating = page.isRegenerating
            let added = merge(page)
            reachedEnd = page.isEmpty && !page.isRegenerating
            return added
        }
        var added: [Status] = []
        var next: String? = firstSinceID
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
            // 再生成中の結果は揃っておらず、返った投稿の間にも、最も新しい投稿より上にも、まだ出ていない投稿が残りうる。
            // 最も新しい投稿から下はギャップにし、上は次の補完でそこから読む。
            isRegenerating = page.isRegenerating
            let gapNewerID = page.isRegenerating ? Self.newestID(of: page) : Self.oldestID(of: page)
            unfilledSinceID = page.isRegenerating ? gapNewerID ?? sinceID : nil
            added += merge(page)
            if let gapNewerID {
                let gap = TimelineGap(newerID: gapNewerID, olderID: sinceID)
                rebuild(statuses: statuses, gaps: gaps + [gap])
                let isFull = page.count >= pageSize
                added += await fillGap(gap.id, pages: isFull ? maxPages - 1 : max(maxPages - 1, 1))
            }
            next = refillSinceID.map { refillSinceID in
                if let unfilledSinceID {
                    // 再生成中だった。基準より古い側は、読み込み済みかギャップに含めてある。
                    // これより新しいところから読み直すとその間を読み飛ばし、古いところから読み直すとギャップが重なるため。
                    unfilledSinceID
                } else {
                    // 読み終えた範囲を読み直すと、同じ範囲にギャップがもう1つできるため。
                    Self.newer(refillSinceID, Self.newestID(of: page) ?? sinceID)
                }
            }
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

    /// ギャップを読み、新たに加わった投稿を新しい順に返す。読み切れなかった分はギャップとして残す。
    /// そのギャップがない、または読み込み中なら何もせずnilを返す。
    ///
    /// ギャップを閉じるのは0件が返ったときだけにする。求めた件数より少なく返すサーバーでは、満杯でないページの先にも投稿が残っているため。
    /// 満杯のページなら、続きは次の読み込みに任せる。満杯でないページなら、その場でもう1回だけ読み、0件ならギャップを閉じる。
    /// 間が空のギャップを、もう一度読み込むまで残さないため。
    public func loadGap(_ id: String, from direction: GapDirection) async throws -> [Status]? {
        guard gaps.contains(where: { $0.id == id }), !loadingGapIDs.contains(id) else { return nil }
        loadingGapIDs.insert(id)
        failedGaps[id] = nil
        defer { loadingGapIDs.remove(id) }

        var added: [Status] = []
        for attempt in 0..<2 {
            // 読んでいる間に削除などで並びが変わっていても、ギャップはIDで探し直す。
            guard let gap = gaps.first(where: { $0.id == id }) else { break }
            let page: TimelinePage
            do {
                page = try await fetch(Self.query(for: gap, from: direction, limit: pageSize))
            } catch {
                // 取り消しは失敗ではないので、読めなかったことにしない。
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    failedGaps[id] = ErrorPresentation(error)
                }
                // 確かめるための2回目が失敗しても、1回目で読めた分は反映済みなので、ギャップを残して返す。
                guard attempt > 0 else { throw error }
                logger.error("gap confirmation failed: \(SciaLog.describe(error), privacy: .public)")
                break
            }
            added += merge(page)
            guard shrink(id, by: page, from: direction), page.count < pageSize, !page.isRegenerating else { break }
        }
        return added.sorted { StatusID.isNewer($0.id, than: $1.id) }
    }

    private static func query(for gap: TimelineGap, from direction: GapDirection, limit: Int) -> TimelineQuery {
        switch direction {
        case .fromNewer: TimelineQuery(maxID: gap.newerID, sinceID: gap.olderID, limit: limit)
        case .fromOlder: TimelineQuery(maxID: gap.newerID, minID: gap.olderID, limit: limit)
        }
    }

    /// 読んだページの分だけギャップを縮める。0件なら閉じる。
    /// 再生成中のページは結果が揃っておらず、返った投稿の間にもまだ出ていない投稿が残りうるため、0件でなくても端を動かさない。
    /// ギャップが残っていればtrueを返す。
    private func shrink(_ id: String, by page: TimelinePage, from direction: GapDirection) -> Bool {
        var remaining = gaps
        guard let index = remaining.firstIndex(where: { $0.id == id }) else { return false }
        guard !page.isRegenerating else { return true }
        if page.isEmpty {
            remaining.remove(at: index)
            rebuild(statuses: statuses, gaps: remaining)
            return false
        }
        switch direction {
        case .fromNewer:
            if let oldestFetched = Self.oldestID(of: page) {
                remaining[index] = remaining[index].narrowed(newerID: oldestFetched)
            }
        case .fromOlder:
            if let newestFetched = Self.newestID(of: page) {
                remaining[index] = remaining[index].narrowed(olderID: newestFetched)
            }
        }
        rebuild(statuses: statuses, gaps: remaining)
        return true
    }

    /// ギャップを新しい側から最大`pages`ページ読み、加わった投稿を返す。失敗したらそこで止め、ギャップを残す。
    private func fillGap(_ id: String, pages: Int) async -> [Status] {
        var added: [Status] = []
        for _ in 0..<max(pages, 0) {
            guard gaps.contains(where: { $0.id == id }) else { break }
            do {
                guard let page = try await loadGap(id, from: .fromNewer) else { break }
                added += page
            } catch {
                logger.error("fill gap failed: \(SciaLog.describe(error), privacy: .public)")
                break
            }
        }
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
            // 読めなかった投稿の編集が読めたら、読めなかった行をその投稿に置き換える。
            if unreadableItems.contains(where: { $0.id == edited.id }) {
                return merge([edited]).isEmpty ? .none : .entriesChanged
            }
            return replace(edited) ? .entriesChanged : .none
        case .delete(let id):
            deletedIDs.insert(id)
            // 元の投稿が消えると、それをブーストした投稿も表示できなくなる。
            pending.removeAll { $0.id == id || $0.reblog?.id == id }
            unreadableItems.removeAll { $0.id == id }
            let remaining = entries.filter { entry in
                switch entry {
                case .status(let status): status.id != id && status.reblog?.id != id
                case .unreadable(let item): item.id != id
                case .gap, .notification, .pinned: true
                }
            }
            guard remaining.count != entries.count else { return .none }
            entries = remaining
            return .entriesChanged
        case .notification, .filtersChanged, .unhandled:
            return .none
        }
    }

    /// 同じIDの投稿と、それをブーストした投稿の中身を差し替える。編集や、お気に入りなどの操作の結果を反映する。
    /// 表示に関わる変化があればtrueを返す。
    @discardableResult
    public func replace(_ updated: Status) -> Bool {
        updateStatus(updated.id) { _ in updated }
    }

    /// 同じIDの投稿と、それをブーストした投稿の中身を`transform`で変える。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) -> Bool {
        pending = pending.map { Self.updating(id, in: $0, transform) }
        let replaced = entries.map { entry -> TimelineEntry in
            guard case .status(let status) = entry else { return entry }
            return .status(Self.updating(id, in: status, transform))
        }
        guard replaced != entries else { return false }
        entries = replaced
        return true
    }

    /// 保留していた投稿をIDの順に合流させ、新たに加わった投稿を新しい順に返す。
    ///
    /// 読み込んだ末尾より古い投稿は捨てる。末尾に足すと、次に古いページを読むときの`max_id`がずれて、間の投稿を読み飛ばすため。
    /// 読めなかった投稿と同じIDの投稿は、末尾にあっても置き換える。並びの位置は変わらないため。
    public func flushPending() -> [Status] {
        defer { pending.removeAll() }
        var arrivals = pending
        if !reachedEnd, let oldestID = itemIDs.last {
            let unreadableIDs = Set(unreadableItems.map(\.id))
            arrivals = arrivals.filter { StatusID.isNewer($0.id, than: oldestID) || unreadableIDs.contains($0.id) }
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
    /// ギャップの中に届いた投稿を既読にしても、新しい側の端との間は読み込んでいないため、新しい側の端と比べる。
    public var hasUnloadedUnread: Bool {
        guard let lastReadID else { return false }
        return gaps.contains { StatusID.isNewer($0.newerID, than: lastReadID) }
    }

    #if DEBUG
    /// 新しい方から`count`件の投稿と、その間のギャップを忘れる。切断している間に投稿を取りこぼした状態を、実データで再現する検証用。
    public func debugForgetNewest(_ count: Int) {
        let remaining = Array(statuses.dropFirst(count))
        let newestKept = remaining.first?.id
        unreadableItems.removeAll { item in newestKept.map { StatusID.isNewer(item.id, than: $0) } ?? true }
        // 新しい側の端の投稿を忘れたギャップは、補完で読み直す範囲に含まれるので消す。
        rebuild(statuses: remaining, gaps: gaps.filter { gap in newestKept.map { !StatusID.isNewer(gap.newerID, than: $0) } ?? false })
    }
    #endif

    // MARK: - 並べ替え

    /// ページの投稿と読めなかった投稿のうち、まだないものを足し、足した投稿を新しい順に返す。
    private func merge(_ page: TimelinePage) -> [Status] {
        let known = Set(itemIDs)
        let newUnreadable = page.unreadable.filter { !known.contains($0.id) && !deletedIDs.contains($0.id) }
        unreadableItems = Self.unique(unreadableItems + newUnreadable)
        let added = merge(page.statuses)
        if added.isEmpty, !newUnreadable.isEmpty {
            rebuild(statuses: statuses, gaps: gaps)
        }
        return added
    }

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

    /// 投稿と読めなかった投稿をIDの新しい順に並べ、ギャップを新しい側の端の投稿のすぐ下に置く。
    /// 画面は要素をIDで区別するため、同じIDのギャップは1つにする。同じ基準で補完が重なると、同じ範囲のギャップができる。
    /// 読めなかった投稿は、同じIDの投稿が読めていれば外す。
    private func rebuild(statuses: [Status], gaps: [TimelineGap]) {
        let statusIDs = Set(statuses.map(\.id))
        unreadableItems.removeAll { statusIDs.contains($0.id) }
        let items = (statuses.map { ($0.id, TimelineEntry.status($0)) } + unreadableItems.map { ($0.id, TimelineEntry.unreadable($0)) })
            .sorted { StatusID.isNewer($0.0, than: $1.0) }
        var seenGapIDs: Set<String> = []
        let sortedGaps = gaps
            .filter { seenGapIDs.insert($0.id).inserted }
            .sorted { StatusID.isNewer($0.newerID, than: $1.newerID) }
        var result: [TimelineEntry] = []
        result.reserveCapacity(items.count + sortedGaps.count)
        var gapIndex = sortedGaps.startIndex
        for (id, item) in items {
            while gapIndex < sortedGaps.endIndex, StatusID.isNewer(sortedGaps[gapIndex].newerID, than: id) {
                result.append(.gap(sortedGaps[gapIndex]))
                gapIndex += 1
            }
            result.append(item)
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

    private static func newer(_ lhs: String, _ rhs: String) -> String {
        StatusID.isNewer(lhs, than: rhs) ? lhs : rhs
    }

    /// ページの中で最も新しいID。読めなかった投稿も含める。
    private static func newestID(of page: TimelinePage) -> String? {
        page.ids.max { StatusID.isNewer($1, than: $0) }
    }

    /// ページの中で最も古いID。読めなかった投稿も含める。
    private static func oldestID(of page: TimelinePage) -> String? {
        page.ids.min { StatusID.isNewer($1, than: $0) }
    }

    /// 同じIDは1つにする。
    private static func unique(_ items: [UnreadableItem]) -> [UnreadableItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    static func updating(_ id: Status.ID, in status: Status, _ transform: (Status) -> Status) -> Status {
        if status.id == id { return transform(status) }
        if let reblog = status.reblog, reblog.id == id { return status.replacingReblog(with: transform(reblog)) }
        return status
    }
}
