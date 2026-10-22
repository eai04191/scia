/// スレッドの画面に並べる投稿。押した投稿と、その前後の会話を持つ。
///
/// 字下げせず、すべて同じ幅で平らに並べる。返信は返信先の直後に、深さ優先で並べ、同じ返信先への返信は古い順にする。
/// こうすると、すぐ上の行が返信先になる行が多くなり、線でつなげる。
@MainActor
public final class ThreadStore {
    /// 押した投稿。ブーストを押したときは、ブーストされた投稿。
    public let focusID: Status.ID
    private var statuses: [Status.ID: Status]
    /// 押した投稿から返信先をたどった投稿のID。古い順。
    private var ancestorIDs: [Status.ID] = []
    /// 消えた投稿。あとからストリーミングで届いても足さない。
    private var deletedIDs: Set<Status.ID> = []
    /// 会話を読み始めてからストリーミングで足した返信。読んだ会話に含まれていなくても残す。読み終えるまでに届いた返信は、読んだ会話に入っていないことがあるため。
    /// それより前に足した返信は残さない。切れている間に消えた投稿を、読み直した会話で消すため。
    private var receivedWhileLoading: Set<Status.ID> = []
    /// 会話を読み始めてから、編集や操作の結果で差し替えた投稿。読み直した会話の応答は、それより古いことがあるため、手元の内容を残す。
    private var updatedWhileLoading: Set<Status.ID> = []
    /// スレッドで当てるサーバーのフィルター。nilなら当てない。
    private let filtering: StatusFiltering?

    /// - Parameter filtering: スレッドで当てるサーバーのフィルター。押した投稿は、押して開いたものなので隠さない。
    public init(focus: Status, filtering: StatusFiltering? = nil) {
        focusID = focus.id
        statuses = [focus.id: focus]
        self.filtering = filtering
        rebuild()
    }

    /// 並びの順の要素。
    public private(set) var entries: [TimelineEntry] = []

    /// 会話を読み始めるときに呼ぶ。これ以降にストリーミングで足した返信は、読んだ会話に含まれていなくても残す。
    public func beginLoading() {
        receivedWhileLoading = []
        updatedWhileLoading = []
    }

    /// 読み込んだ会話で、押した投稿のほかの投稿を置き換える。
    /// - Parameter focus: 読み直した押した投稿。読み直していなければnilで、手元の投稿を使う。
    public func apply(_ context: StatusContext, focus updatedFocus: Status? = nil) {
        let focus = updatedWhileLoading.contains(focusID) ? statuses[focusID] : updatedFocus ?? statuses[focusID]
        let received = receivedWhileLoading.compactMap { statuses[$0] }
        let updated = updatedWhileLoading.compactMap { statuses[$0] }
        statuses = [:]
        for status in received + context.ancestors + context.descendants where !deletedIDs.contains(status.id) {
            statuses[status.id] = status
        }
        // 読み直した会話に残っている投稿だけ、手元の新しい内容に戻す。
        for status in updated where statuses[status.id] != nil {
            statuses[status.id] = status
        }
        if let focus, !deletedIDs.contains(focus.id) {
            statuses[focus.id] = focus
        }
        ancestorIDs = context.ancestors.map(\.id)
        receivedWhileLoading = []
        updatedWhileLoading = []
        rebuild()
    }

    /// 返信先がスレッドの中にある新着を足し、スレッドの中の投稿の編集と削除を反映する。表示に関わる変化があればtrueを返す。
    /// ストリーミングにはスレッド単位のストリームがないため、ホームのストリームなどに届いたものから拾う。
    /// フォローしていない人から自分への返信は、ホームには流れず、メンションの通知だけで届くため、通知の投稿も拾う。
    @discardableResult
    public func receive(_ event: StreamingEvent) -> Bool {
        switch event {
        case .update(let status):
            return add(status)
        case .notification(let notification):
            guard notification.type == .mention, let status = notification.status else { return false }
            return add(status)
        case .statusUpdate(let edited):
            return replace(edited)
        case .delete(let id):
            return removeStatus(id)
        case .filtersChanged, .unhandled:
            return false
        }
    }

    private func add(_ status: Status) -> Bool {
        guard status.reblog == nil, !deletedIDs.contains(status.id), statuses[status.id] == nil,
              let parentID = status.inReplyToId, statuses[parentID] != nil
        else { return false }
        statuses[status.id] = status
        receivedWhileLoading.insert(status.id)
        rebuild()
        return true
    }

    /// 同じIDの投稿の中身を差し替える。編集や、お気に入りなどの操作の結果を反映する。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func replace(_ updated: Status) -> Bool {
        updateStatus(updated.id) { _ in updated }
    }

    /// 同じIDの投稿の中身を`transform`で変える。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) -> Bool {
        guard let status = statuses[id] else { return false }
        let updated = transform(status)
        guard updated != status else { return false }
        statuses[id] = updated
        updatedWhileLoading.insert(id)
        rebuild()
        return true
    }

    /// 消えた投稿を除く。その投稿への返信は、返信先が離れた行として残す。表示に関わる変化があればtrueを返す。
    @discardableResult
    public func removeStatus(_ id: Status.ID) -> Bool {
        deletedIDs.insert(id)
        guard statuses.removeValue(forKey: id) != nil else { return false }
        rebuild()
        return true
    }

    private func rebuild() {
        let chain = ancestorIDs.filter { statuses[$0] != nil } + [focusID]
        let chainIDs = Set(chain)
        var children: [Status.ID: [Status]] = [:]
        for status in statuses.values where !chainIDs.contains(status.id) {
            guard let parentID = status.inReplyToId else { continue }
            children[parentID, default: []].append(status)
        }
        for parentID in children.keys {
            children[parentID]?.sort { StatusID.isNewer($1.id, than: $0.id) }
        }
        var ordered: [Status] = []
        var placed: Set<Status.ID> = []
        func appendSubtree(_ status: Status) {
            guard placed.insert(status.id).inserted else { return }
            ordered.append(status)
            for child in children[status.id] ?? [] {
                appendSubtree(child)
            }
        }
        // 祖先へのほかの返信は、その祖先の直後に置き、押した投稿より上に並べる。
        for id in chain {
            if let status = statuses[id] {
                placed.insert(id)
                ordered.append(status)
            }
            for child in children[id] ?? [] {
                appendSubtree(child)
            }
        }
        // 返信先が消えたか読めなかった投稿は、返信先が分からないため、最後に古い順に並べる。
        let orphans = statuses.values
            .filter { !placed.contains($0.id) }
            .sorted { StatusID.isNewer($1.id, than: $0.id) }
        for orphan in orphans {
            appendSubtree(orphan)
        }
        // 隠す投稿を除くと、その投稿への返信は返信先が離れた行になり、札で返信先を示す。
        entries = ordered
            .filter { $0.id == focusID || !(filtering?.verdict(for: $0).isHidden ?? false) }
            .map(TimelineEntry.status)
    }
}
