public import Foundation
import Synchronization
public import Testing

/// テストが手で進める時計。実際の時間がどれだけ過ぎても進まないので、負荷で遅れても待つ処理の順が変わらない。
/// 待つ処理には`Clock`として渡すか、`sleep`と`date`を関数として渡す。
public final class TestClock: Clock, Sendable {
    public struct Instant: InstantProtocol {
        public var offset: Duration

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
    }

    private let state = Mutex(State())
    /// `date`の、時計を進めていないときの値。
    private let origin: Date

    public init(origin: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.origin = origin
    }

    public var now: Instant { state.withLock { $0.now } }

    public var minimumResolution: Duration { .zero }

    /// 時計の今を日時で表したもの。日時で今を受け取る処理に渡す。
    public var date: Date {
        let offset = now.offset.components
        return origin.addingTimeInterval(TimeInterval(offset.seconds) + TimeInterval(offset.attoseconds) / 1e18)
    }

    /// 時計が進むのを待っている処理の数。待ち始めたかを、テストが確かめてから時計を進めるのに使う。
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// 今から`duration`以内に締め切りの来る待ちの数。長い待ち（pingの時間切れなど）と分けて、次に起こしたい待ちが揃ったかを確かめる。
    public func sleeperCount(dueWithin duration: Duration) -> Int {
        state.withLock { state in
            let limit = state.now.advanced(by: duration)
            return state.sleepers.values.filter { $0.deadline <= limit }.count
        }
    }

    /// 締め切りまでちょうど`duration`残っている待ちの数。
    public func sleeperCount(remaining duration: Duration) -> Int {
        state.withLock { state in
            let now = state.now
            return state.sleepers.values.filter { now.duration(to: $0.deadline) == duration }.count
        }
    }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume: Result<Void, any Error>? = state.withLock { state in
                    if deadline <= state.now { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let resume {
                    continuation.resume(with: resume)
                }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    /// `duration`だけ時計を進め、締め切りの来た待ちを起こす。
    public func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys {
                state.sleepers.removeValue(forKey: id)
            }
            return due.values.sorted { $0.deadline < $1.deadline }
        }
        due.forEach { $0.continuation.resume() }
    }

    /// 締め切りまでちょうど`duration`残っている待ちが`count`個眠り始めてから、時計を`amount`（省略すると`duration`）だけ進める。
    /// 待つ処理は`Task`で始めるので、始める操作のあとでもまだ眠っていないことがある。眠る前に時計を進めると、その待ちはいつまでも起こされない。
    /// 待ちの数だけを見ると、同じ時計を使う別の待ちで揃ったと読むので、起こしたい待ちを長さで指す。
    nonisolated(nonsending) public func advance(
        by amount: Duration? = nil,
        afterSleeping duration: Duration,
        count: Int = 1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil(state: { "眠っている待ちの残り: \(self.remainingDurations)" }, { self.sleeperCount(remaining: duration) >= count }, sourceLocation: sourceLocation)
        advance(by: amount ?? duration)
    }

    private var remainingDurations: [Duration] {
        state.withLock { state in
            let now = state.now
            return state.sleepers.values.map { now.duration(to: $0.deadline) }.sorted()
        }
    }

    /// 待つ処理に関数として渡す、この時計で`duration`だけ待つ関数。
    public var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await sleep(for: duration) }
    }
}
