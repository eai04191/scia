import Foundation
import Synchronization

/// v2の`instance`の応答を、クライアント（とその複製）の間で覚える。版、投稿欄の上限、機能の有無、ストリーミングの接続先が、同じ応答から読む。
///
/// 同時に呼ばれても、同じ目的（`RequestPurpose`）の呼び出しは、読む通信を1回にまとめる。目的が違えば合流させない。レート制限で自動の通信を控えている間に、操作の呼び出しまで断られないため。
/// 読めなければ覚えず、次の呼び出しで読み直す。
/// 取り消された呼び出しは、その場で`CancellationError`で終える。待っている呼び出しがすべて取り消されたら、読む通信も、その場で取り消す。
final class InstanceResponseCache: Sendable {
    struct Response: Sendable {
        let data: Data
        let response: HTTPURLResponse
        let request: URLRequest
    }

    /// JSONのオブジェクトとして読めるかだけを確かめる。読めない応答は覚えない。
    struct JSONObject: Decodable {
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            _ = try decoder.container(keyedBy: Key.self)
        }
    }

    private struct Loading {
        let id: Int
        let purpose: RequestPurpose?
        let task: Task<Void, Never>
        var waiters: [Int: CheckedContinuation<Response, any Error>]
    }

    private struct State {
        var loaded: Response?
        var loadings: [Loading] = []
        /// 番号をとったが、まだ待ち始めていない呼び出し。取り消されたらここから外し、待ち始めずに終える。
        var pendingWaiters: Set<Int> = []
        var nextID = 0
    }

    private let state = Mutex(State())

    /// 走っている読み込みを待っている呼び出しの数。
    var waiterCount: Int { state.withLock { $0.loadings.reduce(0) { $0 + $1.waiters.count } } }

    func response(load: @escaping @Sendable () async throws -> Response) async throws -> Response {
        let purpose = RequestPurpose.current
        let waiterID = state.withLock { state in
            state.nextID += 1
            state.pendingWaiters.insert(state.nextID)
            return state.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Response, any Error>? = state.withLock { state in
                    guard state.pendingWaiters.remove(waiterID) != nil else { return .failure(CancellationError()) }
                    if let loaded = state.loaded { return .success(loaded) }
                    if let index = state.loadings.firstIndex(where: { $0.purpose == purpose }) {
                        state.loadings[index].waiters[waiterID] = continuation
                        return nil
                    }
                    state.nextID += 1
                    let id = state.nextID
                    // 読み込みは、待ち先を書き終えてロックを外すまで、終えたことを書けない。
                    let task = Task { [self] in
                        let result: Result<Response, any Error>
                        do {
                            result = .success(try await load())
                        } catch {
                            result = .failure(error)
                        }
                        finish(id, with: result)
                    }
                    state.loadings.append(Loading(id: id, purpose: purpose, task: task, waiters: [waiterID: continuation]))
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            cancel(waiterID)
        }
    }

    private func finish(_ id: Int, with result: Result<Response, any Error>) {
        let waiters: [CheckedContinuation<Response, any Error>] = state.withLock { state in
            guard let index = state.loadings.firstIndex(where: { $0.id == id }) else { return [] }
            let loading = state.loadings.remove(at: index)
            if case .success(let response) = result, state.loaded == nil {
                state.loaded = response
            }
            return Array(loading.waiters.values)
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func cancel(_ waiterID: Int) {
        let (waiter, task): (CheckedContinuation<Response, any Error>?, Task<Void, Never>?) = state.withLock { state in
            if state.pendingWaiters.remove(waiterID) != nil { return (nil, nil) }
            guard let index = state.loadings.firstIndex(where: { $0.waiters[waiterID] != nil }) else { return (nil, nil) }
            let waiter = state.loadings[index].waiters.removeValue(forKey: waiterID)
            guard state.loadings[index].waiters.isEmpty else { return (waiter, nil) }
            return (waiter, state.loadings.remove(at: index).task)
        }
        waiter?.resume(throwing: CancellationError())
        task?.cancel()
    }
}
