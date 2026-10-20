/// お気に入り、ブースト、ブックマークを付け外しする。サーバーの結果を待たずに表示へ反映し、失敗したら戻す。
@MainActor
public final class StatusInteractions {
    public enum Action: Hashable, Sendable {
        case favourite
        case reblog
        case bookmark
    }

    /// APIを呼ぶ口。テストでは差し替える。
    public struct Operations: Sendable {
        public var favourite: @Sendable (Status.ID) async throws -> Status
        public var unfavourite: @Sendable (Status.ID) async throws -> Status
        public var reblog: @Sendable (Status.ID) async throws -> Status
        public var unreblog: @Sendable (Status.ID) async throws -> Status
        public var bookmark: @Sendable (Status.ID) async throws -> Status
        public var unbookmark: @Sendable (Status.ID) async throws -> Status

        public init(
            favourite: @escaping @Sendable (Status.ID) async throws -> Status,
            unfavourite: @escaping @Sendable (Status.ID) async throws -> Status,
            reblog: @escaping @Sendable (Status.ID) async throws -> Status,
            unreblog: @escaping @Sendable (Status.ID) async throws -> Status,
            bookmark: @escaping @Sendable (Status.ID) async throws -> Status,
            unbookmark: @escaping @Sendable (Status.ID) async throws -> Status
        ) {
            self.favourite = favourite
            self.unfavourite = unfavourite
            self.reblog = reblog
            self.unreblog = unreblog
            self.bookmark = bookmark
            self.unbookmark = unbookmark
        }

        public init(client: MastodonClient) {
            self.init(
                favourite: { try await client.favourite($0) },
                unfavourite: { try await client.unfavourite($0) },
                reblog: { try await client.reblog($0) },
                unreblog: { try await client.unreblog($0) },
                bookmark: { try await client.bookmark($0) },
                unbookmark: { try await client.unbookmark($0) }
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

    public init(operations: Operations, update: @escaping Update) {
        self.operations = operations
        self.update = update
    }

    /// `status`（ブーストなら元の投稿）の状態を反転する。同じ操作の結果を待っている間は何もせずfalseを返す。
    /// 失敗したら表示を戻してから投げる。
    @discardableResult
    public func toggle(_ action: Action, on status: Status) async throws -> Bool {
        let target = status.displayed
        let key = Key(statusID: target.id, action: action)
        guard inFlight.insert(key).inserted else { return false }
        defer { inFlight.remove(key) }

        let turningOn = !Self.isOn(action, in: target)
        update(target.id) { Self.setting(action, turningOn, on: $0) }
        do {
            let result = try await call(action, turningOn, target.id)
            // 投稿全体を置き換えると、待っている間に届いた編集や、並行して成功した別の操作を古い内容で戻すため、この操作の結果だけを反映する。
            update(target.id) { Self.adopting(action, of: result, on: $0) }
        } catch {
            update(target.id) { Self.setting(action, !turningOn, on: $0) }
            throw error
        }
        return true
    }

    public static func isOn(_ action: Action, in status: Status) -> Bool {
        switch action {
        case .favourite: status.favourited
        case .reblog: status.reblogged
        case .bookmark: status.bookmarked
        }
    }

    private static func setting(_ action: Action, _ isOn: Bool, on status: Status) -> Status {
        switch action {
        case .favourite: status.settingFavourited(isOn)
        case .reblog: status.settingReblogged(isOn)
        case .bookmark: status.settingBookmarked(isOn)
        }
    }

    private static func adopting(_ action: Action, of result: Status, on status: Status) -> Status {
        switch action {
        case .favourite: status.adoptingFavourite(of: result)
        case .reblog: status.adoptingReblog(of: result)
        case .bookmark: status.adoptingBookmark(of: result)
        }
    }

    private func call(_ action: Action, _ turningOn: Bool, _ id: Status.ID) async throws -> Status {
        switch (action, turningOn) {
        case (.favourite, true): try await operations.favourite(id)
        case (.favourite, false): try await operations.unfavourite(id)
        case (.reblog, true): try await operations.reblog(id)
        case (.reblog, false): try await operations.unreblog(id)
        case (.bookmark, true): try await operations.bookmark(id)
        case (.bookmark, false): try await operations.unbookmark(id)
        }
    }
}
