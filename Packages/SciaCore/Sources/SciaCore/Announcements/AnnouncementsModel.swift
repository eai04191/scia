import Foundation
import os

/// お知らせのリストの状態。行がないときの表示と、読み込みの失敗の表示に使う。
public enum AnnouncementsContentState: Equatable, Sendable {
    case loading
    case loaded
    /// シートで開いたときか引っぱったときに読めなかった。読めていた行は残す。
    case failed(ErrorPresentation)
}

/// お知らせのリストに並べる行。
public enum AnnouncementListItem: Hashable, Sendable, Identifiable {
    /// - Parameter showsUnreadMark: 未読の点を付けるか。シートを開いている間は、既読にしたあとも付けておく。
    case announcement(Announcement, showsUnreadMark: Bool)
    case unreadable(UnreadableItem)

    public var id: String {
        switch self {
        case .announcement(let announcement, _): "announcement:\(announcement.id)"
        case .unreadable(let item): "unreadable:\(item.id)"
        }
    }
}

/// お知らせのリストの画面への命令。iOSでは`AnnouncementsViewController`が従う。
@MainActor
public protocol AnnouncementsDisplay: AnyObject {
    /// 行を並べ直す。並びはこのモデルが決める。行が消えたり増えたりしても、どれも操作によらない変化か、行の中の変化なので動かさない。
    func setItems(_ items: [AnnouncementListItem])
    func setContentState(_ state: AnnouncementsContentState)
}

/// サーバーのお知らせのリストを持ち、読み込み、既読、リアクションの通信を受け持つ。決まりはdocs/announcements.mdにある。
///
/// セッションの間ずっと`user`のストリームを購読し、つながるたびにお知らせを読み直す。シートを開いていない間も、アカウントのボタンに未読の数を出すため。
@MainActor
public final class AnnouncementsModel {
    /// APIを呼ぶ口。テストでは差し替える。
    public struct Operations: Sendable {
        public var list: @Sendable () async throws -> AnnouncementList
        public var dismiss: @Sendable (Announcement.ID) async throws -> Void
        public var addReaction: @Sendable (Announcement.ID, String) async throws -> Void
        public var removeReaction: @Sendable (Announcement.ID, String) async throws -> Void

        public init(
            list: @escaping @Sendable () async throws -> AnnouncementList,
            dismiss: @escaping @Sendable (Announcement.ID) async throws -> Void,
            addReaction: @escaping @Sendable (Announcement.ID, String) async throws -> Void,
            removeReaction: @escaping @Sendable (Announcement.ID, String) async throws -> Void
        ) {
            self.list = list
            self.dismiss = dismiss
            self.addReaction = addReaction
            self.removeReaction = removeReaction
        }

        public init(client: MastodonClient) {
            self.init(
                list: { try await client.announcements() },
                dismiss: { try await client.dismissAnnouncement($0) },
                addReaction: { try await client.addAnnouncementReaction($0, name: $1) },
                removeReaction: { try await client.removeAnnouncementReaction($0, name: $1) }
            )
        }
    }

    /// 結果を待っているリアクションの操作を見分ける。
    struct ReactionKey: Hashable {
        let announcementID: Announcement.ID
        let name: String
    }

    /// 結果を待っているリアクションの操作。
    struct PendingReaction {
        /// 付けるか外すか。
        let isOn: Bool
        /// カスタム絵文字の画像。読み直しの応答にまだないリアクションを足し直すときと、外したリアクションを失敗して戻すときに使う。
        let customEmoji: CustomEmoji?
        /// 今の数に、押した結果を手元で足し引きした分が入っているか。サーバーから届いた数に置き換わったら、押した結果を含まないので偽にする。
        /// 失敗したときは、入っていれば足し引きを戻し、入っていなければ数は変えずに自分がしたかだけを戻す。
        var countIncludesChange = true
    }

    /// 結果を伝えるお知らせのリストの画面。開いている間だけ付く。
    public weak var display: (any AnnouncementsDisplay)? {
        didSet { showItems() }
    }
    /// 未読の数が変わったときに呼ぶ。アカウントのボタンの点と、メニューの項目の件数に使う。
    public var onUnreadCountChange: (Int) -> Void = { _ in }
    /// リアクションの付け外しに失敗して戻したときに呼ぶ。知らせ方と、出す理由は作る側が決める。
    public var onReactionFailure: (any Error) -> Void = { _ in }
    /// 新しい順に並べたお知らせ。
    public private(set) var announcements: [Announcement] = []
    /// 読めなかったお知らせ。
    public private(set) var unreadable: [UnreadableItem] = []
    public private(set) var unreadCount = 0
    public private(set) var contentState: AnnouncementsContentState = .loading

    private let operations: Operations
    private let streamingHub: StreamingHub?
    /// このモデルが始めた処理の持ち主。セッションの持ち主の子で、セッションを閉じたときにも閉じる。
    private let tasks: TaskScope
    /// APIが401を返したときに呼ぶ。ログアウトされたとして止め、ログインし直しを促すのはセッションに任せる。
    private let onUnauthorized: () -> Void
    private let logger = SciaLog.logger(category: "announcements")
    private var streamingSubscription: StreamingHub.Subscription?
    private var isInForeground = true
    /// 読み直している途中の読み込み。重ねて読まない。
    private var loading: Task<Void, Never>?
    /// 今の読み込みを、シートで開いたときか引っぱったときに始めたか。失敗をシートに出すかを決める。
    private var loadingIsVisible = false
    private var hasLoaded = false
    /// お知らせのリストの中身を手元で変えた回数。読んでいる間にストリーミングで届いた変化を、古い応答で戻さないよう、変わっていたら読み直す。
    private var changeCount = 0
    /// 既読を送っていて、結果を待っているお知らせ。読み直しで未読に戻さない。
    private var dismissing: Set<Announcement.ID> = []
    /// 結果を待っているリアクション。読み直しで押す前に戻さない。
    private var pendingReactions: [ReactionKey: PendingReaction] = [:]
    /// シートを開いている間に未読だったお知らせ。既読にしても、閉じるまで点を残す。開いていなければnil。
    private var markedUnread: Set<Announcement.ID>?
    /// 走り終えていない処理の数。止めたあとに何も起きないことを、テストが確かめるのに使う。
    public var runningTaskCount: Int { tasks.runningCount }

    /// - Parameter streamingHub: nilなら購読しない。ダミーのセッションとテストで使う。
    public init(operations: Operations, streamingHub: StreamingHub?, tasks: TaskScope, onUnauthorized: @escaping () -> Void) {
        self.operations = operations
        self.streamingHub = streamingHub
        self.tasks = tasks
        self.onUnauthorized = onUnauthorized
    }

    /// セッションを始めたときに呼ぶ。購読を始め、お知らせを読む。
    public func start() {
        startStreaming()
        reload(purpose: .display)
    }

    public func enterBackground() {
        isInForeground = false
        streamingSubscription?.cancel()
        streamingSubscription = nil
    }

    /// 戻ったら購読し直し、つながったところで読み直す。
    public func enterForeground() {
        isInForeground = true
        startStreaming()
    }

    private func startStreaming() {
        guard isInForeground, streamingSubscription == nil, let streamingHub, !tasks.isClosed else { return }
        streamingSubscription = streamingHub.subscribe(.user) { [weak self] activity in
            self?.streamingDidChange(activity)
        }
    }

    func streamingDidChange(_ activity: StreamingHub.Activity) {
        guard !tasks.isClosed else { return }
        switch activity {
        case .connected:
            // 切れていた間の追加、削除、リアクションを取りこぼさないよう、つながるたびに読み直す。
            // つながる前に始めた読み込みの応答は、読んだあとからつながるまでの変化を含まないので、使わずに読み直させる。
            changeCount += 1
            reload(purpose: .display)
        case .event(let event):
            apply(event)
        case .poll, .outage:
            break
        }
    }

    /// ストリーミングで届いたお知らせのイベントを反映する。デバッグで流すお知らせと、部品カタログも、ここから入れる。
    public func apply(_ event: StreamingEvent) {
        switch event {
        case .announcement(let announcement):
            receive(announcement)
        case .announcementReaction(let update):
            receive(update)
        case .announcementDelete(let id):
            logger.info("announcement deleted")
            changeCount += 1
            unreadable.removeAll { $0.id == id }
            setAnnouncements(announcements.filter { $0.id != id })
        case .update, .statusUpdate, .delete, .notification, .filtersChanged, .notificationsMerged, .emojiReaction, .unhandled:
            break
        }
    }

    // MARK: - シート

    /// シートを開いたときに呼ぶ。今の未読に点を付け、読み直す。
    public func appear() {
        markedUnread = Set(announcements.filter(\.isUnread).map(\.id))
        showItems()
        reload(purpose: .action, isVisible: true)
    }

    /// シートを閉じたときに呼ぶ。点を消す。
    public func disappear() {
        markedUnread = nil
    }

    /// シートで引っぱったときに呼ぶ。読み終えるまで待てるタスクを返す。
    @discardableResult
    public func refresh() -> Task<Void, Never>? {
        reload(purpose: .action, isVisible: true)
    }

    /// シートで行が画面に出たときに呼ぶ。未読なら既読にしてサーバーに送る。
    public func didShow(_ id: Announcement.ID) {
        guard let announcement = announcements.first(where: { $0.id == id }), announcement.isUnread, !dismissing.contains(id) else { return }
        dismissing.insert(id)
        // アカウントのボタンの点と件数は、送った時点で数から外す。
        update(id) { $0.read = true }
        logger.info("announcement dismiss start")
        tasks.run(.action) { [weak self, operations] in
            do {
                try await operations.dismiss(id)
                self?.logger.info("announcement dismiss done")
                // 既読にする前に送った読み込みの応答は、未読のままなので使わせない。
                self?.changeCount += 1
            } catch let error as MastodonAPIError where error.statusCode == 404 {
                // 取り下げられたあと。既読にするものがないので、送り直さない。
                self?.logger.info("announcement dismiss found nothing")
            } catch {
                guard let self, !tasks.isClosed, !(error is CancellationError) else { return }
                // 使う人にできることがないので知らせない。未読に戻し、次に行が画面に出たときに送り直す。
                logger.error("announcement dismiss failed: \(SciaLog.describe(error), privacy: .public)")
                reportIfUnauthorized(error)
                dismissing.remove(id)
                update(id) { $0.read = false }
                return
            }
            self?.dismissing.remove(id)
        }
    }

    // MARK: - 読み込み

    /// 読み直す。読んでいる途中なら、その読み込みに任せる。
    /// - Parameter isVisible: シートで開いたときか引っぱったときか。失敗をシートに出す。
    @discardableResult
    func reload(purpose: RequestPurpose, isVisible: Bool = false) -> Task<Void, Never>? {
        if isVisible {
            loadingIsVisible = true
        }
        if let loading { return loading }
        loading = tasks.run(purpose) { [weak self] in
            await self?.load()
            self?.loading = nil
            self?.loadingIsVisible = false
        }
        return loading
    }

    private func load() async {
        logger.info("announcements load start")
        do {
            var list: AnnouncementList
            repeat {
                let changesBefore = changeCount
                list = try await operations.list()
                guard !tasks.isClosed else { return }
                if changeCount == changesBefore { break }
                logger.info("announcements load restart after change")
            } while true
            hasLoaded = true
            unreadable = list.unreadable
            setAnnouncements(list.announcements.map(applyingLocalChanges))
            setContentState(.loaded)
            logger.info("announcements load done count=\(list.announcements.count, privacy: .public) unreadable=\(list.unreadable.count, privacy: .public)")
        } catch {
            guard !tasks.isClosed, !(error is CancellationError) else { return }
            logger.error("announcements load failed: \(SciaLog.describe(error), privacy: .public)")
            reportIfUnauthorized(error)
            // 出しているお知らせは消さない。自動の読み込みの失敗はログだけにする。
            if loadingIsVisible {
                setContentState(.failed(ErrorPresentation(error)))
            }
        }
    }

    /// 読んだお知らせに、結果を待っている既読とリアクションを重ねる。読んだ応答が、押す前の状態のことがあるため。
    private func applyingLocalChanges(_ announcement: Announcement) -> Announcement {
        var announcement = announcement
        if dismissing.contains(announcement.id) {
            announcement.read = true
        }
        for (key, pending) in pendingReactions where key.announcementID == announcement.id {
            let isMine = announcement.reactions.first { $0.name == key.name }?.me == true
            // 届いた数は、押した結果をまだ含まない数か、もう含む数のどちらか。含んでいなければ重ね、重ねたかを覚える。
            // ストリーミングのお知らせは自分がしたかを持たず、手元の値を残すので、ここでは重ねない。
            let reapplies = isMine != pending.isOn
            if reapplies {
                announcement.reactions = Self.setting(key.name, pending.isOn, in: announcement.reactions, customEmoji: pending.customEmoji)
            }
            pendingReactions[key]?.countIncludesChange = reapplies
        }
        return announcement
    }

    // MARK: - ストリーミング

    /// 新しいお知らせを足し、同じIDなら差し替える。中身にない既読と自分のリアクションは、手元の値を残す。
    private func receive(_ incoming: Announcement) {
        logger.info("announcement received")
        changeCount += 1
        var announcement = incoming
        if let existing = announcements.first(where: { $0.id == incoming.id }) {
            announcement.read = incoming.read ?? existing.read
            announcement.reactions = incoming.reactions.map { reaction in
                var reaction = reaction
                reaction.me = reaction.me ?? existing.reactions.first { $0.name == reaction.name }?.me
                return reaction
            }
        }
        // お知らせのリストを読んだときに読めなかったお知らせが、読める形で届いたら差し替える。
        unreadable.removeAll { $0.id == incoming.id }
        setAnnouncements(announcements.filter { $0.id != incoming.id } + [applyingLocalChanges(announcement)])
    }

    /// リアクションの数を届いた数に置き換える。自分がしたかは手元の値を残す。
    private func receive(_ reactionUpdate: AnnouncementReactionUpdate) {
        changeCount += 1
        update(reactionUpdate.announcementID) { announcement in
            var reactions = announcement.reactions
            pendingReactions[ReactionKey(announcementID: reactionUpdate.announcementID, name: reactionUpdate.name)]?.countIncludesChange = false
            if let index = reactions.firstIndex(where: { $0.name == reactionUpdate.name }) {
                reactions[index].count = reactionUpdate.count
                // 自分がしているなら、届いた数が自分を含まない値でも残す。
                if reactionUpdate.count == 0, reactions[index].me != true {
                    reactions.remove(at: index)
                }
            } else if reactionUpdate.count > 0 {
                // サーバーは最初にリアクションされた順に並べるので、新しい絵文字は末尾に足す。
                reactions.append(AnnouncementReaction(name: reactionUpdate.name, count: reactionUpdate.count, me: nil, url: reactionUpdate.url, staticUrl: reactionUpdate.staticUrl))
            }
            announcement.reactions = reactions
        }
    }

    // MARK: - リアクション

    /// 並んでいるリアクションを押したとき。自分のリアクションを付け外しする。同じリアクションの結果を待っている間は何もしない。
    public func toggleReaction(_ name: String, on id: Announcement.ID) {
        guard let announcement = announcements.first(where: { $0.id == id }) else { return }
        let isMine = announcement.reactions.first { $0.name == name }?.me == true
        send(name, !isMine, on: id, customEmoji: nil)
    }

    /// 絵文字のシートで選んだとき。自分がすでにしている絵文字なら、付けたままにする。
    /// - Parameter customEmoji: カスタム絵文字なら、届くまでの行に描く画像。
    public func addReaction(_ name: String, customEmoji: CustomEmoji?, to id: Announcement.ID) {
        guard let announcement = announcements.first(where: { $0.id == id }) else { return }
        guard announcement.reactions.first(where: { $0.name == name })?.me != true else { return }
        send(name, true, on: id, customEmoji: customEmoji)
    }

    private func send(_ name: String, _ isOn: Bool, on id: Announcement.ID, customEmoji: CustomEmoji?) {
        let key = ReactionKey(announcementID: id, name: name)
        guard pendingReactions[key] == nil else { return }
        // 外すときは、数が0になって消したボタンを失敗して戻すときに、画像も戻せるよう持っておく。
        let customEmoji = customEmoji ?? announcements.first { $0.id == id }?.reactions.first { $0.name == name }?.customEmoji
        pendingReactions[key] = PendingReaction(isOn: isOn, customEmoji: customEmoji)
        // 取り消せる操作なので、サーバーの結果を待たずに表示へ反映する。
        update(id) { $0.reactions = Self.setting(name, isOn, in: $0.reactions, customEmoji: customEmoji) }
        logger.info("announcement reaction start on=\(isOn, privacy: .public)")
        tasks.run(.action) { [weak self, operations] in
            do {
                if isOn {
                    try await operations.addReaction(id, name)
                } else {
                    try await operations.removeReaction(id, name)
                }
                self?.logger.info("announcement reaction done")
                self?.pendingReactions[key] = nil
                // 押す前に送った読み込みの応答は、押した結果を含まないので使わせない。
                self?.changeCount += 1
            } catch {
                guard let self, !tasks.isClosed, !(error is CancellationError) else { return }
                logger.error("announcement reaction failed: \(SciaLog.describe(error), privacy: .public)")
                reportIfUnauthorized(error)
                let countIncludesChange = pendingReactions[key]?.countIncludesChange ?? true
                pendingReactions[key] = nil
                update(id) { $0.reactions = Self.reverting(name, isOn, in: $0.reactions, customEmoji: customEmoji, countIncludesChange: countIncludesChange) }
                onReactionFailure(error)
            }
        }
    }

    /// 付け外しに失敗した操作を戻した並び。今の数がサーバーから届いた数なら、押した結果を含まないので、数は変えずに自分がしたかだけを戻す。
    static func reverting(_ name: String, _ isOn: Bool, in reactions: [AnnouncementReaction], customEmoji: CustomEmoji?, countIncludesChange: Bool) -> [AnnouncementReaction] {
        guard !countIncludesChange else { return setting(name, !isOn, in: reactions, customEmoji: customEmoji) }
        var reactions = reactions
        guard let index = reactions.firstIndex(where: { $0.name == name }) else {
            // 外すのに失敗したが、待っている間に届いた0件でボタンが消えていたら、自分のリアクションとして戻す。数は届いた0のままで、1と出る。
            if !isOn {
                reactions.append(AnnouncementReaction(name: name, count: 0, me: true, url: customEmoji?.url, staticUrl: customEmoji?.staticUrl))
            }
            return reactions
        }
        reactions[index].me = !isOn
        // 付けるのに失敗して、自分のリアクションもなく数も0なら、ボタンを消す。
        if reactions[index].count == 0, isOn {
            reactions.remove(at: index)
        }
        return reactions
    }

    /// 自分のリアクションを付けた、または外したリアクションの並び。付けるときは数を1増やし、なければ末尾に足す。外すときは数を1減らし、0になったら消す。
    static func setting(_ name: String, _ isOn: Bool, in reactions: [AnnouncementReaction], customEmoji: CustomEmoji?) -> [AnnouncementReaction] {
        var reactions = reactions
        guard let index = reactions.firstIndex(where: { $0.name == name }) else {
            if isOn {
                reactions.append(AnnouncementReaction(name: name, count: 1, me: true, url: customEmoji?.url, staticUrl: customEmoji?.staticUrl))
            }
            return reactions
        }
        reactions[index].me = isOn
        reactions[index].count = ServerCount.clamped(reactions[index].count + (isOn ? 1 : -1))
        if !isOn, reactions[index].count == 0 {
            reactions.remove(at: index)
        }
        return reactions
    }

    // MARK: - 並び

    private func update(_ id: Announcement.ID, _ change: (inout Announcement) -> Void) {
        guard let index = announcements.firstIndex(where: { $0.id == id }) else { return }
        var announcements = announcements
        change(&announcements[index])
        setAnnouncements(announcements)
    }

    private func setAnnouncements(_ announcements: [Announcement]) {
        // サーバーと同じ基準で並べ、新しいものを上にする。
        self.announcements = announcements.sorted { ($0.sortDate, $0.id) > ($1.sortDate, $1.id) }
        // シートを開いている間に届いた未読にも、閉じるまで点を残す。
        if markedUnread != nil {
            markedUnread?.formUnion(self.announcements.filter(\.isUnread).map(\.id))
        }
        let count = self.announcements.count(where: \.isUnread)
        if count != unreadCount {
            unreadCount = count
            onUnreadCountChange(count)
        }
        showItems()
    }

    private func setContentState(_ state: AnnouncementsContentState) {
        contentState = state
        display?.setContentState(state)
    }

    private func showItems() {
        guard let display else { return }
        let marked = markedUnread ?? []
        let items = announcements.map { AnnouncementListItem.announcement($0, showsUnreadMark: marked.contains($0.id)) } + unreadable.map(AnnouncementListItem.unreadable)
        display.setItems(items)
        display.setContentState(contentState)
    }

    private func reportIfUnauthorized(_ error: any Error) {
        if let error = error as? MastodonAPIError, error.isUnauthorized {
            onUnauthorized()
        }
    }
}
