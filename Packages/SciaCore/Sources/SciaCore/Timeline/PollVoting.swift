/// 投票と、投票の結果の読み直し。投票は取り消せないため、お気に入りなどと違い、サーバーの結果を待ってから表示へ反映する。
@MainActor
public final class PollVoting {
    /// APIを呼ぶ口。テストでは差し替える。
    public struct Operations: Sendable {
        public var vote: @Sendable (Poll.ID, [Int]) async throws -> Poll
        public var poll: @Sendable (Poll.ID) async throws -> Poll

        public init(
            vote: @escaping @Sendable (Poll.ID, [Int]) async throws -> Poll,
            poll: @escaping @Sendable (Poll.ID) async throws -> Poll
        ) {
            self.vote = vote
            self.poll = poll
        }

        public init(client: MastodonClient) {
            self.init(
                vote: { try await client.vote($0, choices: $1) },
                poll: { try await client.poll($0) }
            )
        }
    }

    private let operations: Operations
    private let update: StatusInteractions.Update
    /// 結果を待っている投票。同じ投票を重ねて送らない。
    public private(set) var inFlight: Set<Poll.ID> = []
    /// 結果を待っている読み直し。同じ投票を重ねて読み直さない。
    public private(set) var refreshing: Set<Poll.ID> = []
    /// 投票が反映された回数。読み直している間に投票が反映されたら、読み直した結果は投票の前のものなので捨てる。
    private var adoptedVotes: [Poll.ID: Int] = [:]

    public init(operations: Operations, update: @escaping StatusInteractions.Update) {
        self.operations = operations
        self.update = update
    }

    /// `status`（ブーストなら元の投稿）の投票に、`choices`の選択肢で投票し、結果をすべての一覧に反映する。
    /// 同じ投票の結果を待っている間と、選択肢が空のときは、何もせずfalseを返す。
    @discardableResult
    public func vote(_ choices: Set<Int>, on status: Status) async throws -> Bool {
        let target = status.displayed
        guard let poll = target.poll, !choices.isEmpty, inFlight.insert(poll.id).inserted else { return false }
        defer { inFlight.remove(poll.id) }
        let result = try await operations.vote(poll.id, choices.sorted())
        adoptedVotes[poll.id, default: 0] += 1
        update(target.id) { $0.adoptingPoll(result) }
        return true
    }

    /// `status`（ブーストなら元の投稿）の投票を読み直し、すべての一覧に反映する。
    /// 投票を送っている間と、同じ投票を読み直している間は、何もせずfalseを返す。送っている投票は、その結果で反映する。
    @discardableResult
    public func refresh(_ status: Status) async throws -> Bool {
        let target = status.displayed
        guard let poll = target.poll, !inFlight.contains(poll.id), refreshing.insert(poll.id).inserted else { return false }
        defer { refreshing.remove(poll.id) }
        let votes = adoptedVotes[poll.id, default: 0]
        let result = try await operations.poll(poll.id)
        guard adoptedVotes[poll.id, default: 0] == votes else { return true }
        update(target.id) { $0.adoptingPoll(result) }
        return true
    }
}
