public import Foundation
import os

/// タイムラインの投稿を新しい順に持つ。RESTで読んだページと、ストリーミングで届いたイベントを合わせる。
///
/// 投稿はIDの順に並べる。RESTのページングがIDを境に読むため、表示の順もIDに揃えておくと、境目で読み飛ばしや重複が起きない。
/// ただし、ストリーミングで届いた投稿のうち、一覧で最も新しい投稿よりIDが古いものは、届いた順に一番上へ積む。
/// ほかのサーバーの投稿は名乗る日時でIDが付くため、配送が遅れた投稿をIDの順に入れると、読み終えた行の間に入って読み逃すため。
/// 補完や古いページを読む境目は、表示の順ではなくIDで決める。
@MainActor
public final class TimelineStore {
    public typealias Fetch = @Sendable (TimelineQuery) async throws -> TimelinePage

    /// 新しい順。
    public private(set) var entries: [TimelineEntry] = [] {
        didSet { forgetDerivedIDs() }
    }
    /// これより古い投稿はない。
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false
    /// 直近の読み込みで、サーバーがホームを再生成中だった。結果が揃っていないため、時間をおいて読み直す。
    public private(set) var isRegenerating = false
    /// ストリーミングで届き、まだ挿入していない投稿。届いた順。
    public private(set) var pending: [Status] = []
    /// 見た中で最も新しい投稿のID。サーバーに保存する既読位置に使う。
    public private(set) var lastReadID: String?
    /// 見た中で一覧の最も上にある位置。これより上の投稿を未読として数える。
    /// 遅れて届いて一番上に積んだ投稿は、IDが`lastReadID`より古くても上にあるため、IDとは別に持つ。
    private var lastReadPosition: DisplayPosition?
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
    /// ミュートかブロックした相手のアカウントのID。その人の投稿とブーストを除き、あとから届いても足さない。
    private var excludedAccountIDs: Set<String> = []
    /// 読めなかった投稿。同じIDの投稿が読めたら外す。
    private var unreadableItems: [UnreadableItem] = []
    /// フィルターで出さない投稿。一覧には並べないが、読めなかった投稿と同じく、続きを読む位置には使う。
    /// 1ページの全部が隠れても、その先へ進めるようにするため。編集でフィルターに一致しなくなれば、一覧に戻す。
    private var hiddenStatuses: [Status] = [] {
        didSet { forgetDerivedIDs() }
    }
    /// 遅れて届いて一番上に積んだ投稿の位置。ここにない投稿は、IDの位置に並べる。
    private var lateArrivalPositions: [String: DisplayPosition] = [:] {
        didSet { forgetDerivedIDs() }
    }
    /// `loadedIDs`と`itemIDs`を、並びが変わるまで使い回す。流れの速い一覧では、届くたびに全件から作り直すと重くなるため。
    private var cachedLoadedIDs: Set<String>?
    private var cachedItemIDs: [String]?
    /// 遅れて届いた投稿に振った番号の最後。後に届いた投稿ほど大きい。
    private var lateArrivalSequence = 0
    /// 投稿の応答で入れ、まだストリーミングでも補完でも届いていない自分の投稿のID。
    private var unconfirmedPostedIDs: Set<String> = []
    private let pageSize: Int
    private let filtering: StatusFiltering?
    /// フィルターの期限が切れたかを決める、今の時刻。
    private let now: @MainActor () -> Date
    private let fetch: Fetch
    private let logger = SciaLog.logger(category: "timeline")

    /// - Parameters:
    ///   - filtering: この一覧で当てるサーバーのフィルター。nilなら当てない。
    ///   - now: 今の時刻を返す。フィルターの期限が切れたかを決めるのに使う。
    public init(pageSize: Int, filtering: StatusFiltering? = nil, now: @escaping @MainActor () -> Date = { Date() }, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.filtering = filtering
        self.now = now
        self.fetch = fetch
    }

    /// 一覧に並べる投稿。新しい順。フィルターで出さない投稿は含まない。
    public var statuses: [Status] { entries.compactMap(\.status) }

    /// フィルターで出さない投稿も含めた、読み込んだ投稿。
    private var allStatuses: [Status] { statuses + hiddenStatuses }

    /// `allStatuses`のID。
    private var loadedIDs: Set<String> {
        if let cachedLoadedIDs { return cachedLoadedIDs }
        var ids = Set(entries.lazy.compactMap(\.status?.id))
        ids.formUnion(hiddenStatuses.lazy.map(\.id))
        cachedLoadedIDs = ids
        return ids
    }

    /// 読めた投稿も読めなかった投稿もない。読めなかった投稿しかなくても、続きは読めるため空ではない。
    public var isEmpty: Bool { itemIDs.isEmpty }

    /// 読めた投稿と読めなかった投稿のID。IDの新しい順で、遅れて届いて一番上に積んだ投稿もIDの位置に置く。続きを読む位置に使う。
    /// 読めなかった投稿も含めるのは、1ページの全部が読めなかったときにも、その先へ進めるようにするため。
    /// フィルターで出さない投稿も含める。
    private var itemIDs: [String] {
        if let cachedItemIDs { return cachedItemIDs }
        let shown = entries.compactMap { entry -> String? in
            switch entry {
            case .status(let status): status.id
            case .unreadable(let item): item.id
            case .gap, .notification, .pinned, .account: nil
            }
        }
        let ids = hiddenStatuses.isEmpty && lateArrivalPositions.isEmpty
            ? shown
            : (shown + hiddenStatuses.map(\.id)).sorted { StatusID.isNewer($0, than: $1) }
        cachedItemIDs = ids
        return ids
    }

    private func forgetDerivedIDs() {
        cachedLoadedIDs = nil
        cachedItemIDs = nil
    }

    /// 補完で、これより新しい投稿を読む基準。投稿の応答で入れた自分の投稿は、届いたと確かめるまで使わない。
    private var fillBaseID: String? {
        itemIDs.first { !unconfirmedPostedIDs.contains($0) }
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
    /// サーバーがホームを再生成中なら既読位置の周りは読まず、返った投稿の間をギャップにする。
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
        // 再生成中の結果は揃っておらず、返った投稿の間にもまだ出ていない投稿が残りうる。最も新しい投稿から最も古い投稿までをギャップにする。
        // 最も古い投稿より下は古いページの読み込みで、最も新しい投稿より上は次の補完で読む。
        if latest.isRegenerating, let newest = Self.newestID(of: latest), let oldest = Self.oldestID(of: latest), newest != oldest {
            loadedGaps.append(TimelineGap(newerID: newest, olderID: oldest))
        }
        let unique = Dictionary(loaded.flatMap(\.statuses).filter { !isDeleted($0) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        unreadableItems = Self.unique(loaded.flatMap(\.unreadable).filter { !deletedIDs.contains($0.id) })
        // 読み直した一覧はIDの順に並べる。
        lateArrivalPositions = [:]
        rebuild(statuses: Array(unique.values), gaps: loadedGaps)
        // 前の一覧で埋まらなかった基準は、読み直した一覧の範囲の外にあり、そこから読むと読み込み済みの区間にギャップを置いてしまう。
        unfilledSinceID = nil
        isRegenerating = latest.isRegenerating
        reachedEnd = latest.isEmpty && !latest.isRegenerating
        // 読んだ投稿が全部フィルターで隠れて行が1つもないと、続きを読むきっかけがないため、並べる投稿が出るまで古い方を読む。
        // 続きの読み込みに失敗したら空に戻す。隠した投稿だけが残ると空でない扱いになり、読み込み直しが最初の読み込みからやり直さなくなるため。
        if entries.isEmpty, !reachedEnd, !isRegenerating, let oldestID = itemIDs.last {
            do {
                _ = try await fetchOlder(than: oldestID)
            } catch {
                unreadableItems = []
                rebuild(statuses: [], gaps: [])
                reachedEnd = false
                throw error
            }
        }
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

        return try await fetchOlder(than: oldestID)
    }

    /// `oldestID`より古いページを読み、足した投稿のうち一覧に並べたものを返す。
    /// 読んだ投稿が全部フィルターで隠れたら、並べる投稿か読めなかった投稿が出るか、終わりに着くまで続けて読む。
    /// 一覧の末尾の行が画面に出ることが続きを読むきっかけなので、行が増えないと、そこで止まってしまうため。
    private func fetchOlder(than oldestID: String) async throws -> [Status] {
        var maxID = oldestID
        while true {
            let page = try await fetch(TimelineQuery(maxID: maxID, limit: pageSize))
            isRegenerating = page.isRegenerating
            let added = merge(page)
            if page.isEmpty && !page.isRegenerating {
                reachedEnd = true
            }
            // 削除済みの投稿やミュートかブロックした相手の投稿しかなかったときは、一覧に残らないため、ページの一番古い投稿の先へ進む。
            // それでも続きを読む位置が進まなければ、同じページを読み続けないよう止める。
            let pageOldestID = (page.statuses.map(\.id) + page.unreadable.map(\.id)).reduce(itemIDs.last) { oldest, id in oldest.map { Self.older($0, id) } ?? id }
            guard added.isEmpty, !page.isEmpty, page.unreadable.isEmpty, !page.isRegenerating, let next = pageOldestID, next != maxID else {
                return added
            }
            maxID = next
        }
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
    ///
    /// - Parameter progress: 1ページ読むたびに、この補完で新たに加わった投稿の数を渡す。補完の最中に呼ばれてnilを返すときは呼ばない。
    public func fillFromLatest(maxPages: Int = 1, progress: ((Int) -> Void)? = nil) async throws -> [Status]? {
        guard !isFilling else {
            if let newest = fillBaseID {
                refillSinceID = refillSinceID.map { Self.older($0, newest) } ?? newest
            }
            return nil
        }
        isFilling = true
        defer { isFilling = false }

        guard let firstSinceID = unfilledSinceID ?? fillBaseID else {
            let page = try await fetch(TimelineQuery(limit: pageSize))
            isRegenerating = page.isRegenerating
            let added = merge(page)
            reachedEnd = page.isEmpty && !page.isRegenerating
            progress?(added.count)
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
            progress?(added.count)
            if let gapNewerID {
                let gap = TimelineGap(newerID: gapNewerID, olderID: sinceID)
                rebuild(statuses: allStatuses, gaps: gaps + [gap])
                let isFull = page.count >= pageSize
                let addedBeforeGap = added.count
                added += await fillGap(gap.id, pages: isFull ? maxPages - 1 : max(maxPages - 1, 1)) { progress?(addedBeforeGap + $0) }
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
    /// - Parameter progress: 読んだページで投稿が加わるたびに、ここで加わった投稿の数を渡す。満杯でないページの後の、確かめるための読み込みを待たずに渡すため。
    public func loadGap(_ id: String, from direction: GapDirection, progress: (Int) -> Void = { _ in }) async throws -> [Status]? {
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
            let merged = merge(page)
            added += merged
            if !merged.isEmpty {
                progress(added.count)
            }
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
            rebuild(statuses: allStatuses, gaps: remaining)
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
        rebuild(statuses: allStatuses, gaps: remaining)
        return true
    }

    /// ギャップを新しい側から最大`pages`ページ読み、加わった投稿を返す。失敗したらそこで止め、ギャップを残す。
    /// - Parameter progress: 1ページ読むたびに、ここで加わった投稿の数を渡す。
    private func fillGap(_ id: String, pages: Int, progress: (Int) -> Void) async -> [Status] {
        var added: [Status] = []
        for _ in 0..<max(pages, 0) {
            guard gaps.contains(where: { $0.id == id }) else { break }
            do {
                let addedBefore = added.count
                guard let page = try await loadGap(id, from: .fromNewer, progress: { progress(addedBefore + $0) }) else { break }
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
            unconfirmedPostedIDs.remove(status.id)
            // ミュートかブロックした相手の投稿は、届いた時点で捨てる。保留したまま解除すると、合流させるときに除けなくなるため。
            guard !isDeleted(status), !loadedIDs.contains(status.id), !pending.contains(where: { $0.id == status.id }) else {
                return .none
            }
            pending.append(status)
            return pending.count == 1 ? .pendingStarted : .none
        case .statusUpdate(let edited):
            // 読めなかった投稿の編集が読めたら、読めなかった行をその投稿に置き換える。
            // 隠す投稿だったときは、読めなかった行が消えるだけなので、足した投稿ではなく並びの変化で見る。
            if unreadableItems.contains(where: { $0.id == edited.id }) {
                let before = entries
                _ = merge([edited])
                return entries != before ? .entriesChanged : .none
            }
            return replace(edited) ? .entriesChanged : .none
        case .delete(let id):
            return removeStatus(id) ? .entriesChanged : .none
        case .notification, .filtersChanged, .unhandled:
            return .none
        }
    }

    /// 投稿の応答で返った自分の投稿を、新着と同じく保留に溜める。ストリーミングで届くのを待たずに一覧に出すため。
    ///
    /// ストリーミングで届くか、補完で読めるまでは、補完の基準にしない。サーバーは投稿を配信の順に流すので、
    /// 自分の投稿より少し前に他の人が投稿し、まだ届いていない投稿がありうる。届く前に切れて補完すると、それを読み飛ばすため。
    /// 既読位置には、ほかの投稿と同じく使う。自分の投稿より古い投稿があとから届いたら、ほかの遅れた投稿と同じく上に積み、未読に数える。
    ///
    /// 補完の基準にできる投稿が1件もない一覧（最初の読み込みの前や失敗した後、空のホーム）には入れず、ストリーミングを待つ。
    /// 入れると一覧が空でなくなり、読み込み直す代わりに続きを読むようになって、最新のページと応答の投稿の間を読まなくなるため。
    public func receivePosted(_ status: Status) -> EventResult {
        guard fillBaseID != nil else { return .none }
        let result = receive(.update(status))
        unconfirmedPostedIDs.insert(status.id)
        return result
    }

    /// 削除された投稿と、それをブーストした投稿を除く。あとから届いても足さない。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func removeStatus(_ id: Status.ID) -> Bool {
        deletedIDs.insert(id)
        // 元の投稿が消えると、それをブーストした投稿も表示できなくなる。
        pending.removeAll { $0.id == id || $0.reblog?.id == id }
        unreadableItems.removeAll { $0.id == id }
        hiddenStatuses.removeAll { $0.id == id || $0.reblog?.id == id }
        let remaining = entries.filter { entry in
            switch entry {
            case .status(let status), .pinned(let status): status.id != id && status.reblog?.id != id
            case .unreadable(let item): item.id != id
            case .gap, .notification, .account: true
            }
        }
        guard remaining.count != entries.count else { return false }
        entries = remaining
        return true
    }

    /// ミュートかブロックした相手の投稿、その人のブースト、その人の投稿のブーストを除く。あとから届いても足さない。表示に関わる変化があればtrueを返す。
    /// サーバーはミュートやブロックを応答の後でタイムラインに当てることがあり、Mastodonのドキュメントは、届いたものもクライアントで除くよう求めている。
    @discardableResult
    public func excludeAccount(_ id: String) -> Bool {
        excludedAccountIDs.insert(id)
        pending.removeAll(where: isFromExcludedAccount)
        hiddenStatuses.removeAll(where: isFromExcludedAccount)
        let remaining = entries.filter { entry in
            switch entry {
            case .status(let status), .pinned(let status): !isFromExcludedAccount(status)
            case .unreadable, .gap, .notification, .account: true
            }
        }
        guard remaining.count != entries.count else { return false }
        entries = remaining
        return true
    }

    /// ミュートやブロックを解除した相手の投稿を、また足すようにする。除いた投稿は戻さず、読み込み直したときに戻る。
    public func includeAccount(_ id: String) {
        excludedAccountIDs.remove(id)
    }

    /// 同じIDの投稿と、それをブーストした投稿の中身を差し替える。編集や、お気に入りなどの操作の結果を反映する。
    /// サーバーが結果を付け直した投稿なので、ブーストに付いたフィルターの結果もそろえる。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func replace(_ updated: Status) -> Bool {
        updateStatus(updated.id, adoptsFilterResults: true) { _ in updated }
    }

    /// 同じIDの投稿と、それをブーストした投稿の中身を`transform`で変える。表示に関わる変化があればtrueを返す。
    /// 編集でフィルターに一致するようになった投稿は一覧から外し、一致しなくなった投稿は一覧に戻す。
    @discardableResult
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) -> Bool {
        updateStatus(id, adoptsFilterResults: false, transform)
    }

    private func updateStatus(_ id: Status.ID, adoptsFilterResults: Bool, _ transform: (Status) -> Status) -> Bool {
        pending = pending.map { Self.updating(id, in: $0, adoptsFilterResults: adoptsFilterResults, transform) }
        let all = allStatuses
        let replaced = all.map { Self.updating(id, in: $0, adoptsFilterResults: adoptsFilterResults, transform) }
        guard replaced != all else { return false }
        let before = entries
        rebuild(statuses: replaced, gaps: gaps)
        return entries != before
    }

    /// 保留していた投稿を届いた順に一番上へ合流させ、新たに加わった投稿を並べた順に返す。
    ///
    /// 一覧で最も新しい投稿よりIDが新しい投稿は、そのままIDの位置に入るので一番上になる。古い投稿は、その時点で一番上の投稿の上に積む。
    /// 一番上の基準には、積んだ投稿と既読位置の基準のIDも含める。積んだときに一番上だった投稿が消えても、次に届いた投稿を積んである投稿や既読位置より下に入れないため。
    /// 読み込んだ末尾より古い投稿は捨てる。末尾に足すと、次に古いページを読むときの`max_id`がずれて、間の投稿を読み飛ばすため。
    /// 読めなかった投稿と同じIDの投稿は、末尾にあっても置き換え、上に積まずにその位置に入れる。読めなかった行を見て、そこにあると分かっているため。
    /// 行を足すか除くだけで、並びに残る行の中身は変えない。画面は、残る行の中身を比べずに描き直す行を決める。
    public func flushPending() -> [Status] {
        defer { pending.removeAll() }
        var arrivals = pending
        let unreadableIDs = Set(unreadableItems.map(\.id))
        if !reachedEnd, let oldestID = itemIDs.last {
            arrivals = arrivals.filter { StatusID.isNewer($0.id, than: oldestID) || unreadableIDs.contains($0.id) }
        }
        let known = loadedIDs
        var topID = ([itemIDs.first, lastReadPosition?.anchorID] + lateArrivalPositions.values.map(\.anchorID))
            .compactMap(\.self)
            .max { StatusID.isNewer($1, than: $0) }
        for arrival in arrivals where !known.contains(arrival.id) && !unreadableIDs.contains(arrival.id) {
            if let top = topID, !StatusID.isNewer(arrival.id, than: top) {
                lateArrivalSequence += 1
                lateArrivalPositions[arrival.id] = DisplayPosition(anchorID: top, sequence: lateArrivalSequence)
            } else {
                topID = arrival.id
            }
        }
        return merge(arrivals, insertsIntoEntries: true)
    }

    // MARK: - 未読

    /// 画面に表示された投稿を既読にする。既読の位置は新しい方へだけ進む。
    /// - Returns: 一覧の既読の位置が進んだ。進まなければ、未読の数も変わらない。
    @discardableResult
    public func markRead(_ ids: some Sequence<String>) -> Bool {
        let ids = Array(ids)
        return advanceRead(to: ids, positions: ids.map(position(of:)))
    }

    @discardableResult
    private func advanceRead(to ids: [String], positions: [DisplayPosition]) -> Bool {
        lastReadID = Self.advanced(lastReadID, to: ids)
        #if DEBUG
        lastSavableReadID = Self.advanced(lastSavableReadID, to: ids.filter { !debugLocalOnlyIDs.contains($0) })
        #endif
        guard let top = positions.max(by: { $1.isAbove($0) }), lastReadPosition.map({ top.isAbove($0) }) ?? true else { return false }
        lastReadPosition = top
        return true
    }

    private static func advanced(_ current: String?, to ids: [String]) -> String? {
        guard let newest = ids.max(by: { StatusID.isNewer($1, than: $0) }) else { return current }
        if let current, !StatusID.isNewer(newest, than: current) { return current }
        return newest
    }

    #if DEBUG
    /// サーバーにない検証用の投稿のID。見れば手元では既読になるが、サーバーに保存する既読位置には使わない。
    /// 保存すると、本物の投稿がそれを追い越すまで、前回の既読位置から読み始められなくなるため。
    /// リンクカードの取り直しにも使わない。サーバーにない投稿を取りに行く通信になるため。
    public var debugLocalOnlyIDs: Set<String> = []
    /// サーバーに保存できる投稿のうち、見た中で最も新しいもののID。
    private var lastSavableReadID: String?
    #endif

    /// サーバーに保存された既読位置を取り込む。他の端末で読み進めていれば、未読がその分減る。
    /// 既読位置はIDの位置として取り込む。同じIDの投稿が遅れて届いて一番上に積んであっても、その位置にすると、下にある未読まで既読になるため。
    public func applySavedMarker(_ id: String) {
        advanceRead(to: [id], positions: [DisplayPosition(anchorID: id, sequence: 0)])
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

    /// 既読の位置より上にある、読み込み済みの投稿の数。既読の位置が決まっていなければ0。
    public var unreadCount: Int {
        guard let lastReadPosition else { return 0 }
        return entries.lazy.compactMap(\.status).prefix { self.position(of: $0.id).isAbove(lastReadPosition) }.count
    }

    /// 既読の位置より上にギャップがあり、未読は`unreadCount`より多い。
    /// ギャップは新しい側の端の投稿と、その上に積んだ投稿のすぐ下に並ぶため、新しい側の端と既読の位置の基準のIDを比べる。
    public var hasUnloadedUnread: Bool {
        guard let lastReadPosition else { return false }
        return entries.contains { entry in
            guard case .gap(let gap) = entry else { return false }
            return StatusID.isNewer(gap.newerID, than: lastReadPosition.anchorID)
        }
    }

    #if DEBUG
    /// 新しい方から`count`件の投稿と、その間のギャップを忘れる。切断している間に投稿を取りこぼした状態を、実データで再現する検証用。
    public func debugForgetNewest(_ count: Int) {
        let remaining = Array(statuses.sorted { StatusID.isNewer($0.id, than: $1.id) }.dropFirst(count))
        let newestKept = remaining.first?.id
        unreadableItems.removeAll { item in newestKept.map { StatusID.isNewer(item.id, than: $0) } ?? true }
        let hiddenKept = hiddenStatuses.filter { status in newestKept.map { !StatusID.isNewer(status.id, than: $0) } ?? false }
        // 新しい側の端の投稿を忘れたギャップは、補完で読み直す範囲に含まれるので消す。
        rebuild(statuses: remaining + hiddenKept, gaps: gaps.filter { gap in newestKept.map { !StatusID.isNewer(gap.newerID, than: $0) } ?? false })
    }
    #endif

    // MARK: - 並べ替え

    /// ページの投稿と読めなかった投稿のうち、まだないものを足し、足した投稿を新しい順に返す。
    private func merge(_ page: TimelinePage) -> [Status] {
        unconfirmedPostedIDs.subtract(page.statuses.map(\.id))
        let known = Set(itemIDs)
        let newUnreadable = page.unreadable.filter { !known.contains($0.id) && !deletedIDs.contains($0.id) }
        unreadableItems = Self.unique(unreadableItems + newUnreadable)
        let added = merge(page.statuses)
        if added.isEmpty, !newUnreadable.isEmpty {
            rebuild(statuses: allStatuses, gaps: gaps)
        }
        return added
    }

    /// まだない投稿を足し、足した投稿のうち一覧に並べたものを並べた順に返す。
    /// - Parameter insertsIntoEntries: 今の並びに差し込む。並べ直す前に、読めなかった投稿やギャップを変えていないときだけ使える。
    private func merge(_ incoming: [Status], insertsIntoEntries: Bool = false) -> [Status] {
        let known = loadedIDs
        let added = Dictionary(incoming.filter { !known.contains($0.id) && !isDeleted($0) }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            .values
            .sorted { position(of: $0.id).isAbove(position(of: $1.id)) }
        guard !added.isEmpty else { return [] }
        if !insertsIntoEntries || !insert(added) {
            rebuild(statuses: allStatuses + added, gaps: gaps)
        }
        let now = self.now()
        return added.filter { !isFilteredOut($0, now: now) }
    }

    /// `rebuild`と同じ並びになるよう、並べた順の`added`を今の並びに差し込む。差し込めなければfalseを返す。
    /// 流れの速い一覧で、挿入のたびに全件を並べ直すと重くなるため。
    /// 今の並びは、`rebuild`で並べたあと行を除くことしかしていないので、`rebuild`の並びのままになっている。
    /// フィルターで出さない投稿は、フィルターの期限が切れると一覧に戻る。`rebuild`は並べ直すたびにフィルターを当て直すので、
    /// 戻る投稿があれば全件を並べ直す。出していた投稿が、あとからフィルターに一致するようになることはない。
    private func insert(_ added: [Status]) -> Bool {
        let now = self.now()
        guard !hiddenStatuses.contains(where: { !isFilteredOut($0, now: now) }) else { return false }
        let addedIDs = Set(added.map(\.id))
        // 全件から作り直さず、足した投稿のIDを加えて使い回す。手放してから加え、集合のコピーを避ける。
        var loadedIDs = self.loadedIDs
        cachedLoadedIDs = nil
        loadedIDs.formUnion(addedIDs)
        var items: [(position: DisplayPosition, entry: TimelineEntry)] = []
        for status in added {
            if isFilteredOut(status, now: now) {
                hiddenStatuses.append(status)
            } else {
                items.append((position(of: status.id), .status(status)))
            }
        }
        unreadableItems.removeAll { addedIDs.contains($0.id) }
        var result: [TimelineEntry] = []
        result.reserveCapacity(entries.count + items.count)
        var itemIndex = items.startIndex
        for entry in entries {
            if case .unreadable(let item) = entry, addedIDs.contains(item.id) { continue }
            while itemIndex < items.endIndex, isPlaced(items[itemIndex].position, above: entry) {
                result.append(items[itemIndex].entry)
                itemIndex += 1
            }
            result.append(entry)
        }
        result.append(contentsOf: items[itemIndex...].map(\.entry))
        entries = result
        cachedLoadedIDs = loadedIDs
        return true
    }

    /// `rebuild`の並びで、`position`の投稿が`entry`より上に来る。ギャップは、新しい側の端のIDより古い投稿の上に置く。
    private func isPlaced(_ position: DisplayPosition, above entry: TimelineEntry) -> Bool {
        switch entry {
        case .status(let status): position.isAbove(self.position(of: status.id))
        case .unreadable(let item): position.isAbove(self.position(of: item.id))
        case .gap(let gap): !StatusID.isNewer(gap.newerID, than: position.anchorID)
        case .notification, .pinned, .account: false
        }
    }

    /// 投稿と読めなかった投稿をIDの新しい順に並べ、遅れて届いた投稿を積んだ位置に置き、ギャップを新しい側の端の投稿と、その上に積んだ投稿のすぐ下に置く。
    /// 画面は要素をIDで区別するため、同じIDのギャップは1つにする。同じ基準で補完が重なると、同じ範囲のギャップができる。
    /// 読めなかった投稿は、同じIDの投稿が読めていれば外す。フィルターで出さない投稿は並べず、別に持つ。
    private func rebuild(statuses: [Status], gaps: [TimelineGap]) {
        let statusIDs = Set(statuses.map(\.id))
        unreadableItems.removeAll { statusIDs.contains($0.id) }
        let now = self.now()
        hiddenStatuses = statuses.filter { isFilteredOut($0, now: now) }
        let shown = hiddenStatuses.isEmpty ? statuses : statuses.filter { !isFilteredOut($0, now: now) }
        let items = (shown.map { (position(of: $0.id), TimelineEntry.status($0)) } + unreadableItems.map { (position(of: $0.id), TimelineEntry.unreadable($0)) })
            .sorted { $0.0.isAbove($1.0) }
        var seenGapIDs: Set<String> = []
        let sortedGaps = gaps
            .filter { seenGapIDs.insert($0.id).inserted }
            .sorted { StatusID.isNewer($0.newerID, than: $1.newerID) }
        var result: [TimelineEntry] = []
        result.reserveCapacity(items.count + sortedGaps.count)
        var gapIndex = sortedGaps.startIndex
        for (position, item) in items {
            while gapIndex < sortedGaps.endIndex, StatusID.isNewer(sortedGaps[gapIndex].newerID, than: position.anchorID) {
                result.append(.gap(sortedGaps[gapIndex]))
                gapIndex += 1
            }
            result.append(item)
        }
        result.append(contentsOf: sortedGaps[gapIndex...].map(TimelineEntry.gap))
        entries = result
    }

    private func position(of id: String) -> DisplayPosition {
        lateArrivalPositions[id] ?? DisplayPosition(anchorID: id, sequence: 0)
    }

    private func isFilteredOut(_ status: Status, now: Date) -> Bool {
        filtering?.verdict(for: status, now: now).isHidden ?? false
    }

    private func isDeleted(_ status: Status) -> Bool {
        deletedIDs.contains(status.id) || status.reblog.map { deletedIDs.contains($0.id) } ?? false || isFromExcludedAccount(status)
    }

    /// ミュートかブロックした相手の投稿か、その人のブーストか、その人の投稿のブースト。
    private func isFromExcludedAccount(_ status: Status) -> Bool {
        excludedAccountIDs.contains(status.account.id) || status.reblog.map { excludedAccountIDs.contains($0.account.id) } ?? false
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

    /// 一覧の中の位置。IDの位置に並べる投稿は、自分のIDと0。遅れて届いて積んだ投稿は、積んだときに一番上だった投稿のIDと、届いた順の番号。
    /// 同じIDの上では、番号の大きいものほど上に並ぶ。
    private struct DisplayPosition {
        let anchorID: String
        let sequence: Int

        func isAbove(_ other: DisplayPosition) -> Bool {
            anchorID == other.anchorID ? sequence > other.sequence : StatusID.isNewer(anchorID, than: other.anchorID)
        }
    }

    /// - Parameter adoptsFilterResults: ブーストを書き換えるときに、フィルターの結果も元の投稿の結果にそろえる。`Status.replacingReblog(with:adoptsFilterResults:)`を参照。
    static func updating(_ id: Status.ID, in status: Status, adoptsFilterResults: Bool = false, _ transform: (Status) -> Status) -> Status {
        if status.id == id { return transform(status) }
        if let reblog = status.reblog, reblog.id == id { return status.replacingReblog(with: transform(reblog), adoptsFilterResults: adoptsFilterResults) }
        return status
    }
}
