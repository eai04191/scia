import Foundation
import Synchronization
public import Testing

/// テストの進み具合を伝える先。`.stallLimit`を付けたテストの中で`StallProgress.current`で取り、段階が進むたびに`note`を呼ぶ。
/// ほかのタスクやキューから呼ばれるクロージャーにも渡せる。
public struct StallProgress: Sendable {
    @TaskLocal static var log: ProgressLog?

    private let log: ProgressLog?

    /// 今のテストの進み具合を伝える先。`.stallLimit`を付けていないテストでは、伝えても何もしない。
    public static var current: StallProgress { StallProgress(log: log) }

    /// 段階が進んだことを伝える。進んでいないのに呼ぶと固まったのを見逃すので、値が変わったときだけ呼ぶ。
    public func note(_ step: String) {
        log?.note(step)
    }
}

final class ProgressLog: Sendable {
    private struct State {
        var steps: [(step: String, at: Duration)]
    }

    /// 始まってからの時間。見張りと同じ時計で測る。
    private let elapsed: @Sendable () -> Duration
    private let state: Mutex<State>

    init(clock: any Clock<Duration>) {
        elapsed = Self.elapsed(on: clock)
        state = Mutex(State(steps: [("始まった", .zero)]))
    }

    private static func elapsed<C: Clock<Duration>>(on clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    func note(_ step: String) {
        let at = elapsed()
        state.withLock { $0.steps.append((step, at)) }
    }

    var stepCount: Int { state.withLock { $0.steps.count } }

    /// 最後のいくつかの段階の、始まってからの時間。
    var history: String {
        state.withLock { state in
            let recent = state.steps.suffix(8)
            let omitted = state.steps.count - recent.count
            return (omitted > 0 ? "（前の\(omitted)個の段階は省略）\n" : "") + recent.map { "\($0.at.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))) \($0.step)" }.joined(separator: "\n")
        }
    }
}

/// 進み具合が`limit`のあいだ一度も伝わらなかったら、固まったとみなして失敗させるトレイト。`limit`ごとに、その間に伝わった数を見る。スイートに付けると、その中のテストごとに見る。
///
/// テスト全体にかかった時間は見ない。負荷で遅くなっただけの回は、段階が進んでいる限り通す。
/// 固まったら、段階の履歴を失敗に残して、テストをキャンセルする。キャンセルしても`limit`のあいだ終わらなければ、
/// 残りのテストが止まらないよう、プロセスを落とす（`make test`のxcodebuildは、落ちたあとに残りのテストを走らせ直す）。
public struct StallLimitTrait: SuiteTrait, TestTrait, TestScoping {
    let limit: Duration
    let clock: any Clock<Duration>

    public init(limit: Duration, clock: any Clock<Duration> = ContinuousClock()) {
        self.limit = limit
        self.clock = clock
    }

    public var isRecursive: Bool { true }

    public func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let log = ProgressLog(clock: clock)
        let sourceLocation = test.sourceLocation
        let name = test.name
        let limit = limit
        let clock = clock
        let started = log.stepCount
        // タスクグループは子が終わるまで戻らないので、`function`はここを抜けたあとに呼ばれない。
        try await withoutActuallyEscaping(function) { function in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await StallProgress.$log.withValue(log) {
                        try await function()
                    }
                }
                group.addTask {
                    var seen = started
                    while true {
                        try await clock.sleep(for: limit)
                        let count = log.stepCount
                        if count == seen { throw Stalled() }
                        seen = count
                    }
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch is Stalled {
                    Issue.record(Comment(rawValue: "進み具合が\(limit)のあいだ伝わらず、固まったとみなしました\n\(log.history)"), sourceLocation: sourceLocation)
                    group.cancelAll()
                    let killer = Task {
                        try await clock.sleep(for: limit)
                        fatalError("\(name): キャンセルしても終わらないので、プロセスを落とします\n\(log.history)")
                    }
                    defer { killer.cancel() }
                    _ = try? await group.next()
                    throw WaitHang()
                }
            }
        }
    }

    private struct Stalled: Error {}
}

extension Trait where Self == StallLimitTrait {
    /// `StallProgress`に進み具合が`hangLimit`のあいだ伝わらなかったら、固まったとみなして失敗させる。
    public static var stallLimit: Self { StallLimitTrait(limit: hangLimit) }

    /// `StallProgress`に進み具合が`limit`のあいだ伝わらなかったら、固まったとみなして失敗させる。
    public static func stallLimit(_ limit: Duration) -> Self { StallLimitTrait(limit: limit) }
}
