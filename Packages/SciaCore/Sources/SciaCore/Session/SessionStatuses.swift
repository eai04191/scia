/// セッションが持つ、投稿を並べる一覧（`SessionStatusList`）へ、自分の操作で変わった投稿を配る。`AccountSession.statuses`に1つある。
/// 投稿欄から送った結果（`SubmittedDraft`）も、`reflect(_:usingTagsIn:)`でここから配る。
///
/// 同じ投稿が、いくつものタイムライン、通知、開いているプロフィールやスレッドにあることがあるため、どれにも同じ変化を当てる。
/// ストリーミングで届いた変化は、各一覧が自分で受けるので、ここでは配らない。
///
/// 一覧は、`FeedTimelineModel`、`NotificationsModel`、`SavedStatusesModel`を`init(…session:…)`で作ると登録される。
/// `session`を受け取らない一覧（`ThreadModel`、`SearchModel`、`AccountNotificationsModel`、アプリが作る一覧）は、作ったときに`register(_:)`で登録する。
/// 予約投稿の一覧（`ScheduledStatusesModel`）も`register(_:)`で登録する。
/// 弱く持つので、外す必要はない。
///
/// 引用元の囲みは、一覧が持つ投稿を書き換えずに、ここで覚えた変化（`quoteSources`）を出すときに当てる。
@MainActor
public final class SessionStatuses {
    private var lists: [WeakStatusList] = []
    private var scheduledLists: [WeakScheduledList] = []
    /// 引用元の、受け取ったあとの編集、削除、ミュート、ブロック。どの一覧の囲みにも当て、開き直した画面にも引き継ぐ。
    public private(set) var quoteSources = QuoteSourceChanges()
    /// 引用元の変化が変わったときに呼ぶ。開いている一覧の画面に、変わった囲みを描き直させる。
    public var onQuoteSourcesChange: (QuoteSourceChanges, QuoteSourceChange) -> Void = { _, _ in }

    public init() {}

    public func register(_ list: some SessionStatusList) {
        lists.removeAll { $0.list == nil }
        lists.append(WeakStatusList(list: list))
    }

    public func register(_ list: ScheduledStatusesModel) {
        scheduledLists.removeAll { $0.list == nil }
        scheduledLists.append(WeakScheduledList(list: list))
    }

    /// 投稿欄から今のアカウントで送れた結果（`ComposeModel.onSubmitted`）を、ストリーミングの知らせを待たずに一覧へ反映する。
    /// ストリーミングで届くまで数秒かかることがあり、切れている間は届かないため。
    /// - 投稿したら、受け取る一覧（ホームと、返信先を開いているスレッド）に足す（`SessionStatusList.receivePosted(_:)`）
    /// - 予約したら、予約投稿の一覧に足す
    /// - 編集したら、その投稿を持つ一覧すべてで編集後の投稿に置き換え、引用元としても編集したことにする
    /// - Parameter completion: 投稿と編集に付けたハッシュタグを、補完の最近使ったものに足す。
    public func reflect(_ submitted: SubmittedDraft, usingTagsIn completion: ComposeCompletion?) {
        switch submitted {
        case .posted(let posted):
            for list in lists.compactMap(\.list) {
                list.receivePosted(posted)
            }
            completion?.didUse(posted.tags)
        case .scheduled(let scheduled):
            for list in scheduledLists.compactMap(\.list) {
                list.didSchedule(scheduled)
            }
        case .edited(let edited):
            updateStatus(edited.id) { _ in edited }
            changeQuoteSources(.status(edited.id)) { $0.edit(edited) }
            completion?.didUse(edited.tags)
        }
    }

    /// その投稿と、それをブーストした投稿を、どの一覧でも`transform`で変える。お気に入りやブーストの結果、投票、取り直した投稿に使う。
    public func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status) {
        for list in lists.compactMap(\.list) {
            list.updateStatus(id, transform)
        }
    }

    /// 消えた自分の投稿を、どの一覧からも除き、引用元としても消えたことにする。
    /// この端末で消したとき（`StatusDeletion`）と、削除して書き直すために消したとき（`ComposeModel.onRedraftDeleted`）に呼ぶ。
    public func removeStatus(_ id: Status.ID) {
        for list in lists.compactMap(\.list) {
            list.removeStatus(id)
        }
        changeQuoteSources(.status(id)) { $0.delete(id) }
    }

    /// 引用元の変化を覚え、変わったときだけ`onQuoteSourcesChange`を呼ぶ。
    /// ストリーミングで届いた編集と削除、ミュートとブロックの変化にも使う。
    public func changeQuoteSources(_ change: QuoteSourceChange, _ apply: (inout QuoteSourceChanges) -> Void) {
        var changed = quoteSources
        apply(&changed)
        guard changed != quoteSources else { return }
        quoteSources = changed
        onQuoteSourcesChange(changed, change)
    }
}

/// `SessionStatuses`が投稿の変化を配る一覧。
@MainActor
public protocol SessionStatusList: AnyObject {
    /// その投稿と、それをブーストした投稿を`transform`で変える。持っていなければ何もしない。
    func updateStatus(_ id: Status.ID, _ transform: (Status) -> Status)
    /// その投稿と、それをブーストした投稿や、それについての通知を除く。持っていなければ何もしない。
    func removeStatus(_ id: Status.ID)
    /// 投稿欄から送った自分の投稿を受け取る。足す一覧（ホームと、返信先を開いているスレッド）だけが足す。既定では何もしない。
    func receivePosted(_ status: Status)
}

extension SessionStatusList {
    public func receivePosted(_ status: Status) {}
}

/// 引用元の変化の対象。
public enum QuoteSourceChange: Sendable, Equatable {
    /// 投稿が編集されたか、削除された。
    case status(Status.ID)
    /// アカウントをミュートかブロックしたか、解除した。
    case account(String)
}

@MainActor
private struct WeakStatusList {
    weak var list: (any SessionStatusList)?
}

@MainActor
private struct WeakScheduledList {
    weak var list: ScheduledStatusesModel?
}
