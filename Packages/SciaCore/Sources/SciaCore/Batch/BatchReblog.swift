/// まとめてブーストする投稿と、それぞれの送り方。決まりはdocs/batch-actions.mdの「ブースト」にある。
public struct BatchReblogPlan: Sendable {
    public struct Step: Sendable {
        public internal(set) var status: Status
        /// ブースト済みなので、取り消してから付け直す。Mastodonはブースト済みの投稿をもう一度ブーストしても新しく作らず、選んだ順に並ばないため。
        public var reblogsAgain: Bool
    }

    /// 選んだ順。
    public let steps: [Step]
    /// ブーストできずに飛ばす投稿の数。他人のフォロワー限定の投稿や、個別の投稿。
    public let skippedCount: Int

    /// - Parameter statuses: 選んだ順の投稿。同じ投稿（ブーストなら元の投稿）は、先に選んだほうの順番で1度だけブーストする。
    public init(statuses: [Status], myAccountID: String) {
        let unique = BatchTargets.unique(statuses)
        let reblogged = unique.filter { $0.canBeReblogged(by: myAccountID) }
        steps = reblogged.map { Step(status: $0, reblogsAgain: $0.displayed.reblogged) }
        skippedCount = unique.count - reblogged.count
    }

    /// 付け直す投稿の数。
    public var reblogAgainCount: Int {
        steps.filter(\.reblogsAgain).count
    }
}

/// 選んだ投稿をまとめて扱うときの共通の決まり。
public enum BatchTargets {
    /// 同じ投稿（ブーストなら元の投稿）を、先に選んだほうの順番で1度だけ残す。固定した投稿とふだんの行のように、同じ投稿を2つの行で選べるため。
    public static func unique(_ statuses: [Status]) -> [Status] {
        var seen: Set<Status.ID> = []
        return statuses.filter { seen.insert($0.displayed.id).inserted }
    }
}

/// まとめてブーストを、選んだ順に1件ずつ送る。サーバーの応答を待ってから次へ進み、1件ごとに間隔をあける。
/// 失敗したらそこで止め、もう一度`run()`を呼ぶと、失敗した投稿から続ける。
@MainActor
public final class BatchReblog {
    public enum Outcome: Sendable {
        /// 全部ブーストした。
        case finished
        /// `stop()`で止めた。済んだ分はそのまま残す。
        case stopped
        /// `index`番目（0から数える）の投稿で失敗した。
        case failed(index: Int, any Error)
        /// 前に呼んだ`run()`がまだ走っているので、何もしなかった。失敗のチップを続けて押したときなど。
        case alreadyRunning

        public var isAlreadyRunning: Bool {
            if case .alreadyRunning = self { true } else { false }
        }
    }

    /// ブーストを取り消す。受け付けたら戻る。
    public typealias Unreblog = @MainActor (Status) async throws -> Void
    /// ブーストする。受け付けたら戻る。
    public typealias Reblog = @MainActor (Status) async throws -> Void

    public private(set) var steps: [BatchReblogPlan.Step]
    /// 済んだ投稿の数。次に送るのは`steps[completedCount]`。
    public private(set) var completedCount = 0
    public var total: Int { steps.count }
    /// 済んだ数が変わった。
    public var onProgress: (@MainActor () -> Void)?

    private let interval: @MainActor () -> Duration
    private let clock: any Clock<Duration>
    private let unreblog: Unreblog
    private let reblog: Reblog
    private let isRemovalPending: @MainActor (any Error) -> Bool
    private let removalRetryDelays: [Duration]
    private let isReblogged: @MainActor (Status) -> Bool
    private var isStopRequested = false
    /// `run()`が走っている。同じ投稿へ2本で送ると、片方が結果を待っている操作に当たって失敗するため、1本にする。
    public private(set) var isRunning = false
    private var waiting: Task<Void, any Error>?

    /// - Parameters:
    ///   - interval: 1件ごとにあける間隔。ほかのサーバーは、ブーストを秒までの日時で並べるため。
    ///   - isRemovalPending: 取り消した直後のブーストの失敗が、取り消したブーストをサーバーがまだ消し終えていないためのものか。
    ///     Mastodonは取り消しを受け付けても、ブーストを裏の処理で後から消し、消し終えるまでは「既にブーストされています」の422で断る。
    ///   - removalRetryDelays: `isRemovalPending`に当たる失敗のあと、ブーストを送り直すまで待つ長さ。使い切ったら失敗にする。
    ///     ブーストは送り直しても結果が変わらないので、自動で送り直してよい。
    ///   - isReblogged: 送る直前に、投稿がブースト済みかを確かめる。選んでから送るまでの間に、ほかの一覧でブーストしていることがあるため。
    ///     ブースト済みなら、取り消してから付け直す。
    public init(
        plan: BatchReblogPlan,
        interval: @escaping @MainActor () -> Duration,
        clock: any Clock<Duration> = SystemTime.clock,
        isRemovalPending: @escaping @MainActor (any Error) -> Bool = { _ in false },
        removalRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)],
        isReblogged: @escaping @MainActor (Status) -> Bool = { $0.displayed.reblogged },
        unreblog: @escaping Unreblog,
        reblog: @escaping Reblog
    ) {
        steps = plan.steps
        self.interval = interval
        self.clock = clock
        self.isRemovalPending = isRemovalPending
        self.removalRetryDelays = removalRetryDelays
        self.isReblogged = isReblogged
        self.unreblog = unreblog
        self.reblog = reblog
    }

    /// 残りを選んだ順に送る。最初の1件は待たずに送り、そのあとは1件ごとに間隔をあける。
    /// 止められるのは投稿と投稿の間だけにする。取り消してから付け直す途中で止めると、取り消したまま残るため。
    /// 呼んだタスクが取り消されたら（ログアウトやアカウントの切り替えでセッションを閉じたときなど）、間隔の待ちもやめて止める。
    public func run() async -> Outcome {
        guard !isRunning else { return .alreadyRunning }
        isRunning = true
        defer { isRunning = false }
        isStopRequested = false
        var isFirst = true
        while completedCount < steps.count {
            if !isFirst {
                let wait = Task { [clock, interval = interval()] in try await clock.sleep(for: interval) }
                waiting = wait
                await withTaskCancellationHandler {
                    _ = try? await wait.value
                } onCancel: {
                    wait.cancel()
                }
                waiting = nil
            }
            guard !isStopRequested, !Task.isCancelled else { return .stopped }
            isFirst = false
            let index = completedCount
            let step = steps[index]
            do {
                if step.reblogsAgain || isReblogged(step.status) {
                    try await unreblog(step.status)
                    // 続きから送るときは、取り消し済みなので付けるだけにする。付けるときは、取り消したあとの状態から送る。
                    steps[index].reblogsAgain = false
                    steps[index].status = step.status.displayed.settingReblogged(false)
                    try await reblogAfterUnreblog(steps[index].status)
                } else {
                    try await reblog(step.status)
                }
            } catch {
                return .failed(index: index, error)
            }
            completedCount += 1
            onProgress?()
        }
        return .finished
    }

    /// 取り消した直後のブーストを、サーバーが取り消したブーストを消し終えるまで、間をおいて送り直す。
    private func reblogAfterUnreblog(_ status: Status) async throws {
        var delays = removalRetryDelays[...]
        while true {
            do {
                try await reblog(status)
                return
            } catch where isRemovalPending(error) {
                guard let delay = delays.popFirst() else { throw error }
                try await clock.sleep(for: delay)
            }
        }
    }

    /// 次の投稿へ進む前に止める。送っている途中の投稿は、送り終えてから止まる。
    public func stop() {
        isStopRequested = true
        waiting?.cancel()
    }
}
