import Foundation

/// 自分で残した投稿の一覧の種類。
public enum SavedStatusesKind: String, Sendable, CaseIterable {
    case bookmarks
    case favourites

    /// この一覧に入っている印が付いているか。
    public func isSaved(_ status: Status) -> Bool {
        switch self {
        case .bookmarks: status.bookmarked
        case .favourites: status.favourited
        }
    }

    /// この一覧に関わる操作。
    public var action: StatusInteractions.Action {
        switch self {
        case .bookmarks: .bookmark
        case .favourites: .favourite
        }
    }
}

/// ブックマークやお気に入りした投稿の一覧を、サーバーが返す順のまま持つ。決まりはdocs/tabs.mdの「ブックマークとお気に入り」にある。
///
/// 並びはブックマークした順、お気に入りした順で、投稿のIDの順ではないため、`TimelineStore`のようにIDで並べ直さない。
/// 続きは、前のページの応答の`Link`ヘッダーにある位置から読む。
///
/// 最新のページが手元とつながらなければ、間にギャップを置く。ギャップの`newerID`には、間を読むときの`max_id`（上のページの`Link`ヘッダーにあった位置）を入れ、
/// `olderID`には、ギャップの下の行のIDを入れる。間は上から読むことしかできないため、読むたびに`newerID`を次の位置へ進める。
@MainActor
public final class SavedStatusesStore {
    public typealias Fetch = @Sendable (_ maxID: String?) async throws -> SavedStatusesPage

    public let kind: SavedStatusesKind
    /// サーバーの順。読めなかった投稿は、読めたページの後ろに並ぶ。
    public private(set) var entries: [TimelineEntry] = []
    /// これより古いものはない。
    public private(set) var reachedEnd = false
    public private(set) var isLoading = false
    /// 最初の読み込みが済んだ。済むまでは、アプリの中で付けた投稿を先頭に入れない。開いたときの読み込みで、まとめて読むため。
    public private(set) var isLoaded = false
    /// 続きを読むときの`max_id`。
    private var nextMaxID: String?
    /// 削除のイベントで消した投稿のID。削除の前に読み始めた結果に含まれていても、表示に戻さない。
    private var deletedIDs: Set<String> = []
    /// ミュートかブロックした相手のアカウントのID。
    private var excludedAccountIDs: Set<String> = []
    /// 読み込みの最中に、アプリの中で付けた投稿。読み込みを始めたあとにサーバーが受け付けたものは、読んだページに入っていないことがあるため、
    /// 読み込みが済んだら、まだなければ先頭に入れる。
    private var savedDuringLoad: [Status] = []
    /// サーバーのページで読んだ行。最新のページとの重なりは、この行でだけ探す。
    /// アプリの中で先頭に入れた行で探すと、ほかの端末でその前に付けた行が、その行の下にあっても読み落とすため。
    private var fromServerIDs: Set<TimelineEntry.ID> = []
    /// 外すのをサーバーが受け付けた投稿。外したまま残した行を消すのは、この投稿だけにする。
    /// 結果を待っている間に消すと、外すのに失敗して印を戻しても、行が戻らないため。
    private var settledUnsavedIDs: Set<Status.ID> = []
    /// 読み込み中のギャップのID。
    public private(set) var loadingGapIDs: Set<String> = []
    /// 直近の読み込みに失敗したギャップと、その理由。読み直し始めたら外す。
    private var failedGaps: [String: ErrorPresentation] = [:]
    private let fetch: Fetch

    public init(kind: SavedStatusesKind, fetch: @escaping Fetch) {
        self.kind = kind
        self.fetch = fetch
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var statuses: [Status] { entries.compactMap(\.status) }

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

    /// 最新のページで置き換える。読み込み中なら何もせずfalseを返す。
    @discardableResult
    public func loadInitial() async throws -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(nil)
        replace(with: page)
        insertSavedDuringLoad()
        return true
    }

    /// 末尾の続きを読み、並びが変わればtrueを返す。読み込み中、終端に達している、まだ読み込んでいない場合は何もせずfalseを返す。
    @discardableResult
    public func loadOlder() async throws -> Bool {
        guard !isLoading, isLoaded, !reachedEnd, let maxID = nextMaxID else { return false }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(maxID)
        let before = entries
        let added = newEntries(of: page)
        entries += added
        fromServerIDs.formUnion(added.map(\.id))
        // 同じ位置を返し続けるサーバーで、同じページを読み続けないよう止める。
        nextMaxID = page.nextMaxID == maxID ? nil : page.nextMaxID
        reachedEnd = nextMaxID == nil
        insertSavedDuringLoad()
        return entries != before
    }

    /// 最新のページを読み、手元の先頭より新しい分を先頭に足す。ほかの端末で付けた分を拾うため。並びが変わればtrueを返す。
    ///
    /// 重なりは、サーバーのページで読んだ手元の行で探す。その行がページに1つもなく、ページの先がまだあれば、手元との間が埋まらないので、
    /// 読んだページを先頭に足し、手元との間にギャップを置く。手元を置き換えると、下まで読んでいた位置を失うため。
    /// 手元の先頭にギャップが残っていれば（前の読み直しで、上に並べる行がなかった）、その間は新しいギャップに含まれるので、新しいギャップ1つにまとめる。
    /// ページの先がなければ、手元の行はもうサーバーの一覧にないので、一覧を読んだページで置き換える。サーバーのページで読んだ行が手元に1つもないときも置き換える。
    /// 先頭の行は外したまま残した行のことがあり、サーバーの一覧にはないため、先頭に限らず探す。
    /// 重なりより前にある、アプリの中で先頭に入れた行は、サーバーの順の位置へ移す。
    /// 読み込み中か、まだ読み込んでいなければ何もせずfalseを返す。
    @discardableResult
    public func refreshNewest() async throws -> Bool {
        guard !isLoading, isLoaded else { return false }
        isLoading = true
        defer { isLoading = false }

        let page = try await fetch(nil)
        let before = entries
        let known = fromServerIDs.intersection(entries.map(\.id))
        let incoming = Self.entries(of: page)
        if let overlap = incoming.firstIndex(where: { known.contains($0.id) }) {
            let newer = incoming[..<overlap]
            let newerIDs = Set(newer.map(\.id))
            let rest = entries.filter { !newerIDs.contains($0.id) }
            let added = newEntries(newer, known: Set(rest.map(\.id)))
            entries = added + rest
            fromServerIDs.formUnion(added.map(\.id))
        } else if !known.isEmpty, let cursor = page.nextMaxID {
            let added = newEntries(incoming[...], known: [])
            let addedIDs = Set(added.map(\.id))
            let rest = entries.filter { !addedIDs.contains($0.id) }.drop { if case .gap = $0 { true } else { false } }
            let gap = TimelineGap(newerID: cursor, olderID: rest.lazy.compactMap(Self.rawID).first ?? cursor)
            entries = added + [.gap(gap)] + Array(rest)
            fromServerIDs.formUnion(addedIDs)
        } else {
            // 外したまま残した行は、見ている間に付け直せるよう、置き換えても読んだページの下に残す。サーバーの一覧にはもうないため。
            let unsaved = entries.filter { $0.status.map { !kind.isSaved($0) } ?? false }
            replace(with: page)
            entries += newEntries(unsaved[...])
        }
        insertSavedDuringLoad()
        return entries != before
    }

    /// ギャップを上から1ページ読み、並びが変わればtrueを返す。そのギャップがない、または読み込み中なら何もせずnilを返す。
    ///
    /// ギャップの下にある、サーバーのページで読んだ行に重なったら、その手前までを足してギャップを閉じる。重ならなければ読んだ分を足し、ギャップを次の位置へ進める。
    /// ページの先がなければ、下の行はもうサーバーの一覧にないので、ギャップを閉じる。
    /// 重なりより前にある、アプリの中で先頭に入れた行は、サーバーの順の位置へ移す。
    @discardableResult
    public func loadGap(_ id: String) async throws -> Bool? {
        guard let gap = gaps.first(where: { $0.id == id }), !loadingGapIDs.contains(id) else { return nil }
        loadingGapIDs.insert(id)
        failedGaps[id] = nil
        defer { loadingGapIDs.remove(id) }

        let page: SavedStatusesPage
        do {
            page = try await fetch(gap.newerID)
        } catch {
            // 取り消しは失敗ではないので、読めなかったことにしない。
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                failedGaps[id] = ErrorPresentation(error)
            }
            throw error
        }
        // 読んでいる間に一覧を置き換えていたら、ギャップはもうない。
        guard let index = entries.firstIndex(where: { $0.id == .gap(id) }) else { return false }
        let before = entries
        let above = entries[..<index]
        let below = entries[(index + 1)...]
        let knownBelow = fromServerIDs.intersection(below.map(\.id))
        let incoming = Self.entries(of: page)
        let overlap = incoming.firstIndex { knownBelow.contains($0.id) }
        let newer = incoming[..<(overlap ?? incoming.endIndex)]
        let newerIDs = Set(newer.map(\.id))
        let rest = below.filter { !newerIDs.contains($0.id) }
        let added = newEntries(newer, known: Set(above.map(\.id) + rest.map(\.id)))
        // 同じ位置を返し続けるサーバーで、同じページを読み続けないよう止める。
        let next = page.nextMaxID == gap.newerID ? nil : page.nextMaxID
        let remaining: [TimelineEntry] = if overlap == nil, let next { [.gap(gap.narrowed(newerID: next))] } else { [] }
        entries = Array(above) + added + remaining + rest
        fromServerIDs.formUnion(added.map(\.id))
        return entries != before
    }

    /// 読み込みの最中に付けた投稿を、まだなければ先頭に入れる。読み込みに失敗したら呼ばれず、次の読み込みが済んだところで入れる。
    private func insertSavedDuringLoad() {
        let saved = savedDuringLoad
        savedDuringLoad = []
        for status in saved {
            insertAtTop(status)
        }
    }

    /// アプリの中で付けた投稿を、まだなければ先頭に入れる。入れたらtrueを返す。
    /// 外したまま残した行を付け直したときは、すでにあるので動かさない。
    /// 読み込みの最中なら、読み込みが済んだところで入れる。まだ読み込んでいなければ、開いたときの読み込みで読むので入れない。
    @discardableResult
    public func insertSaved(_ status: Status) -> Bool {
        let target = status.displayed
        settledUnsavedIDs.remove(target.id)
        if isLoading {
            savedDuringLoad.removeAll { $0.id == target.id }
            savedDuringLoad.append(target)
            return false
        }
        guard isLoaded else { return false }
        return insertAtTop(target)
    }

    /// 印が付いていて、削除も除きもしていない投稿を、まだなければ先頭に入れる。入れたらtrueを返す。
    @discardableResult
    private func insertAtTop(_ status: Status) -> Bool {
        guard kind.isSaved(status), !deletedIDs.contains(status.id), !isExcluded(status), !entries.contains(where: { $0.id == .status(status.id) }) else { return false }
        entries.insert(.status(status), at: 0)
        return true
    }

    /// 外すのをサーバーが受け付けた。外したまま残した行は、`pruneUnsaved()`で消せるようになる。
    public func markUnsaved(_ status: Status) {
        settledUnsavedIDs.insert(status.displayed.id)
    }

    /// 外したまま残した行のうち、外すのをサーバーが受け付けたものを消す。消したらtrueを返す。
    @discardableResult
    public func pruneUnsaved() -> Bool {
        let remaining = entries.filter { entry in
            guard let status = entry.status else { return true }
            return kind.isSaved(status) || !settledUnsavedIDs.contains(status.id)
        }
        guard remaining.count != entries.count else { return false }
        let removedIDs = Set(entries.compactMap(\.status?.id)).subtracting(remaining.compactMap(\.status?.id))
        settledUnsavedIDs.subtract(removedIDs)
        entries = remaining
        return true
    }

    /// 同じIDの投稿の中身を`transform`で変える。印を外しても行は残す。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) -> Bool {
        let updated = entries.map { entry in
            guard case .status(let status) = entry else { return entry }
            return .status(TimelineStore.updating(id, in: status, transform))
        }
        guard updated != entries else { return false }
        entries = updated
        return true
    }

    /// 削除された投稿を除く。あとから届いても足さない。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func removeStatus(_ id: Status.ID) -> Bool {
        deletedIDs.insert(id)
        let remaining = entries.filter { $0.id != .status(id) && $0.id != .unreadable(id) }
        guard remaining.count != entries.count else { return false }
        entries = remaining
        return true
    }

    /// ミュートかブロックした相手の投稿を除く。あとから届いても足さない。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func excludeAccount(_ id: String) -> Bool {
        excludedAccountIDs.insert(id)
        let remaining = entries.filter { $0.status.map { !isExcluded($0) } ?? true }
        guard remaining.count != entries.count else { return false }
        entries = remaining
        return true
    }

    /// ミュートやブロックを解除した相手の投稿を、また足すようにする。除いた投稿は戻さず、読み込み直したときに戻る。
    public func includeAccount(_ id: String) {
        excludedAccountIDs.remove(id)
    }

    // MARK: - 並べ方

    private func replace(with page: SavedStatusesPage) {
        entries = newEntries(Self.entries(of: page)[...], known: [])
        fromServerIDs = Set(entries.map(\.id))
        nextMaxID = page.nextMaxID
        reachedEnd = page.nextMaxID == nil
        isLoaded = true
    }

    /// ギャップのほかの行の、投稿か読めなかった投稿のID。
    private static func rawID(of entry: TimelineEntry) -> String? {
        switch entry {
        case .status(let status): status.id
        case .unreadable(let item): item.id
        case .gap, .notification, .pinned, .account: nil
        }
    }

    private static func entries(of page: SavedStatusesPage) -> [TimelineEntry] {
        page.statuses.map(TimelineEntry.status) + page.unreadable.map(TimelineEntry.unreadable)
    }

    /// まだない行のうち、削除した投稿と除いた相手の投稿でないものを、順を保って返す。同じIDは先に出たほうを残す。
    private func newEntries(of page: SavedStatusesPage) -> [TimelineEntry] {
        newEntries(Self.entries(of: page)[...])
    }

    private func newEntries(_ incoming: ArraySlice<TimelineEntry>, known: Set<TimelineEntry.ID>? = nil) -> [TimelineEntry] {
        var seen = known ?? Set(entries.map(\.id))
        return incoming.filter { entry in
            switch entry {
            case .status(let status):
                guard !deletedIDs.contains(status.id), !isExcluded(status) else { return false }
            case .unreadable(let item):
                guard !deletedIDs.contains(item.id) else { return false }
            case .gap, .notification, .pinned, .account:
                return false
            }
            return seen.insert(entry.id).inserted
        }
    }

    private func isExcluded(_ status: Status) -> Bool {
        excludedAccountIDs.contains(status.account.id) || status.reblog.map { excludedAccountIDs.contains($0.account.id) } ?? false
    }
}
