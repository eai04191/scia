import Synchronization

/// 開くまで、待っている相手を止めておく門。時間の長さではなく、テストが条件を確かめてから先へ進ませる。開いた後に待つ相手は止めない。
public final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public var isOpen: Bool { state.withLock { $0.isOpen } }

    /// 止められている相手の数。止めている相手が着いたかを、テストが確かめるのに使う。
    public var waiterCount: Int { state.withLock { $0.waiters.count } }

    public func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters.values
        }
        waiters.forEach { $0.resume() }
    }

    /// 開くまで待つ。待っている間に取り消されたら、`CancellationError`を投げる。
    public func wait() async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume: Result<Void, any Error>? = state.withLock { state in
                    if state.isOpen { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let resume {
                    continuation.resume(with: resume)
                }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}
