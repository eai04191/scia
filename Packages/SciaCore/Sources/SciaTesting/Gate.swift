import Synchronization
public import Testing

/// 開くまで、待っている相手を止めておく門。時間の長さではなく、テストが条件を確かめてから先へ進ませる。開いた後に待つ相手は止めない。
public final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state: Mutex<State>
    private let diagnostic: DiagnosticResource

    /// - Parameter isOpen: 開いた状態で作るか。待たせないときにも同じ形で渡すために使う。
    public init(isOpen: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        diagnostic = DiagnosticResource("Gate", sourceLocation: sourceLocation)
        diagnostic.note("作成 open=\(isOpen)")
        state = Mutex(State(isOpen: isOpen))
    }

    public var isOpen: Bool { state.withLock { $0.isOpen } }

    /// 止められている相手の数。止めている相手が着いたかを、テストが確かめるのに使う。
    public var waiterCount: Int { state.withLock { $0.waiters.count } }

    public func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            diagnostic.note("open 解除数=\(state.waiters.count) 待機数=0")
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
                    diagnostic.note("wait #\(id) 待機数=\(state.waiters.count)")
                    return nil
                }
                if let resume {
                    continuation.resume(with: resume)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                let waiter = state.waiters.removeValue(forKey: id)
                diagnostic.note("cancel #\(id) open=\(state.isOpen) 待機数=\(state.waiters.count)")
                return waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
        state.withLock { state in
            diagnostic.note("wait #\(id) 終了 open=\(state.isOpen) 待機数=\(state.waiters.count)")
        }
    }
}
