/// お気に入り、ブースト、ブックマーク、会話のミュート、プロフィールへの固定を付け外しする。サーバーの結果を待たずに表示へ反映し、失敗したら戻す。
@MainActor
public final class StatusInteractions {
    public enum Action: Hashable, Sendable {
        case favourite
        case reblog
        case bookmark
        /// 押した投稿の会話をミュートする。サーバーは会話全体をミュートするが、投稿は会話のIDを持たないため、同じ会話のほかの投稿の`muted`は古いまま残る。
        /// 残った投稿でもう一度ミュートを選んでも、サーバーではミュートしたままで、その投稿の表示が正しくなるだけなので、会話のほかの投稿は読み直さない。
        case muteConversation
        case pin
    }

    /// APIを呼ぶ口。テストでは差し替える。
    public struct Operations: Sendable {
        public var favourite: @Sendable (Status.ID) async throws -> Status
        public var unfavourite: @Sendable (Status.ID) async throws -> Status
        public var reblog: @Sendable (Status.ID, ReblogVisibility) async throws -> Status
        public var unreblog: @Sendable (Status.ID) async throws -> Status
        public var bookmark: @Sendable (Status.ID) async throws -> Status
        public var unbookmark: @Sendable (Status.ID) async throws -> Status
        public var muteConversation: @Sendable (Status.ID) async throws -> Status
        public var unmuteConversation: @Sendable (Status.ID) async throws -> Status
        public var pin: @Sendable (Status.ID) async throws -> Status
        public var unpin: @Sendable (Status.ID) async throws -> Status

        public init(
            favourite: @escaping @Sendable (Status.ID) async throws -> Status,
            unfavourite: @escaping @Sendable (Status.ID) async throws -> Status,
            reblog: @escaping @Sendable (Status.ID, ReblogVisibility) async throws -> Status,
            unreblog: @escaping @Sendable (Status.ID) async throws -> Status,
            bookmark: @escaping @Sendable (Status.ID) async throws -> Status,
            unbookmark: @escaping @Sendable (Status.ID) async throws -> Status,
            muteConversation: @escaping @Sendable (Status.ID) async throws -> Status,
            unmuteConversation: @escaping @Sendable (Status.ID) async throws -> Status,
            pin: @escaping @Sendable (Status.ID) async throws -> Status,
            unpin: @escaping @Sendable (Status.ID) async throws -> Status
        ) {
            self.favourite = favourite
            self.unfavourite = unfavourite
            self.reblog = reblog
            self.unreblog = unreblog
            self.bookmark = bookmark
            self.unbookmark = unbookmark
            self.muteConversation = muteConversation
            self.unmuteConversation = unmuteConversation
            self.pin = pin
            self.unpin = unpin
        }

        public init(client: MastodonClient) {
            self.init(
                favourite: { try await client.favourite($0) },
                unfavourite: { try await client.unfavourite($0) },
                reblog: { try await client.reblog($0, visibility: $1) },
                unreblog: { try await client.unreblog($0) },
                bookmark: { try await client.bookmark($0) },
                unbookmark: { try await client.unbookmark($0) },
                muteConversation: { try await client.muteConversation($0) },
                unmuteConversation: { try await client.unmuteConversation($0) },
                pin: { try await client.pin($0) },
                unpin: { try await client.unpin($0) }
            )
        }
    }

    /// 投稿のIDと変換を受け取り、表示しているすべての一覧で、その投稿とそれをブーストした投稿を変える。
    public typealias Update = @MainActor (Status.ID, (Status) -> Status) -> Void

    private let operations: Operations
    private let update: Update
    /// 結果を待っている操作。同じ投稿への同じ操作を重ねて送らない。
    public private(set) var inFlight: Set<Key> = []

    public struct Key: Hashable, Sendable {
        public let statusID: Status.ID
        public let action: Action
    }

    /// サーバーが操作を受け付けたとき。操作と、結果を反映した投稿（ブーストなら元の投稿）を渡す。
    /// ブックマークやお気に入りの一覧に、付けた投稿を入れるのに使う。失敗して戻したときは呼ばない。
    /// 同じ投稿へのほかの操作の結果を待っている間に押した操作の状態も、渡す投稿に含める。
    public var onSettle: (@MainActor (Action, Status) -> Void)?
    /// 結果を待っている操作がある投稿の、いちばん新しい状態。あとから押した操作には、先に押した操作の見込みの状態が入っているため、押したときの投稿で置き換え、受け付けた結果と戻した状態を重ねる。
    /// `onSettle`に、先に押した操作の、押したときの古い状態を渡さないため。
    private var latest: [Status.ID: Status] = [:]

    public init(operations: Operations, update: @escaping Update) {
        self.operations = operations
        self.update = update
    }

    /// `status`（ブーストなら元の投稿）の状態を反転する。同じ操作の結果を待っている間は何もせずfalseを返す。
    /// 失敗したら表示を戻してから投げる。
    /// - Parameter reblogVisibility: ブーストするときの公開範囲。ほかの操作と、ブーストを取り消すときは使わない。
    @discardableResult
    public func toggle(_ action: Action, on status: Status, reblogVisibility: ReblogVisibility = .accountDefault) async throws -> Bool {
        let target = status.displayed
        let key = Key(statusID: target.id, action: action)
        guard inFlight.insert(key).inserted else { return false }
        defer {
            inFlight.remove(key)
            if !inFlight.contains(where: { $0.statusID == target.id }) {
                latest[target.id] = nil
            }
        }

        let turningOn = !Self.isOn(action, in: target)
        latest[target.id] = Self.setting(action, turningOn, on: target)
        update(target.id) { Self.setting(action, turningOn, on: $0) }
        do {
            let result = try await call(action, turningOn, target.id, reblogVisibility: reblogVisibility)
            // 投稿全体を置き換えると、待っている間に届いた編集や、並行して成功した別の操作を古い内容で戻すため、この操作の結果だけを反映する。
            update(target.id) { Self.adopting(action, of: result, on: $0) }
            let settled = Self.adopting(action, of: result, on: latest[target.id] ?? target)
            latest[target.id] = settled
            onSettle?(action, settled)
        } catch {
            update(target.id) { Self.setting(action, !turningOn, on: $0) }
            latest[target.id] = latest[target.id].map { Self.setting(action, !turningOn, on: $0) }
            throw error
        }
        return true
    }

    public static func isOn(_ action: Action, in status: Status) -> Bool {
        switch action {
        case .favourite: status.favourited
        case .reblog: status.reblogged
        case .bookmark: status.bookmarked
        case .muteConversation: status.muted
        case .pin: status.pinned
        }
    }

    private static func setting(_ action: Action, _ isOn: Bool, on status: Status) -> Status {
        switch action {
        case .favourite: status.settingFavourited(isOn)
        case .reblog: status.settingReblogged(isOn)
        case .bookmark: status.settingBookmarked(isOn)
        case .muteConversation: status.settingMuted(isOn)
        case .pin: status.settingPinned(isOn)
        }
    }

    private static func adopting(_ action: Action, of result: Status, on status: Status) -> Status {
        switch action {
        case .favourite: status.adoptingFavourite(of: result)
        case .reblog: status.adoptingReblog(of: result)
        case .bookmark: status.adoptingBookmark(of: result)
        case .muteConversation: status.settingMuted(result.muted)
        case .pin: status.settingPinned(result.pinned)
        }
    }

    private func call(_ action: Action, _ turningOn: Bool, _ id: Status.ID, reblogVisibility: ReblogVisibility) async throws -> Status {
        switch (action, turningOn) {
        case (.favourite, true): try await operations.favourite(id)
        case (.favourite, false): try await operations.unfavourite(id)
        case (.reblog, true): try await operations.reblog(id, reblogVisibility)
        case (.reblog, false): try await operations.unreblog(id)
        case (.bookmark, true): try await operations.bookmark(id)
        case (.bookmark, false): try await operations.unbookmark(id)
        case (.muteConversation, true): try await operations.muteConversation(id)
        case (.muteConversation, false): try await operations.unmuteConversation(id)
        case (.pin, true): try await operations.pin(id)
        case (.pin, false): try await operations.unpin(id)
        }
    }
}
