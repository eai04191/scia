public import Testing

/// 条件を満たすまで待つ。待つ長さで打ち切らないので、負荷で遅れても落ちない。
/// 固まったときにテストの実行が止まらないよう、`limit`（既定は`hangLimit`）を過ぎたら失敗を残し、`WaitHang`を投げてテストを終える。
/// 失敗を残して先へ進めると、固まったテストは続く待ちのたびに上限まで待ち、上限の何倍もかかるため。
/// 上限は、どれだけ混んでも条件を満たすまでにかからない長さにしてあり、待つ長さの見積もりではない。
/// 条件は、呼び出し元と同じアクター（メインアクターのテストならメインスレッド）で確かめる。
nonisolated(nonsending) public func waitUntil(
    limit: Duration = hangLimit,
    _ condition: nonisolated(nonsending) () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil(limit: limit, state: { nil }, condition, sourceLocation: sourceLocation)
}

/// 条件を満たすまで待ち、上限を過ぎたら、残す失敗に`state`が返す状態を添える。たまにしか固まらない待ちで、固まったときの状態から原因を探すために使う。
nonisolated(nonsending) public func waitUntil(
    limit: Duration = hangLimit,
    state: nonisolated(nonsending) () async -> String?,
    _ condition: nonisolated(nonsending) () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + limit
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            let message = ["条件を満たさないまま、固まったとみなす上限を過ぎました", await state()].compactMap(\.self).joined(separator: "\n")
            Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
            throw WaitHang()
        }
        // メインスレッドで待つテストでも、待っている間にRunLoopを回して画面の更新を進める。
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// 条件を満たすまで、`clock`を`step`ずつ進めながら待つ。どの待ちがどの順に起きるかを確かめないテストで、実際の時間を待たずに時計を進める。
/// 順を確かめるテストでは使わず、待ちが揃ったことを`sleeperCount`で確かめてから、締め切りまで進める。
nonisolated(nonsending) public func waitUntil(
    advancing clock: TestClock,
    by step: Duration,
    _ condition: nonisolated(nonsending) () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil({
        if try await condition() { return true }
        clock.advance(by: step)
        return false
    }, sourceLocation: sourceLocation)
}

/// 待つのを打ち切って、固まったとみなすまでの長さ。
public let hangLimit: Duration = .seconds(60)

/// 待ちが固まったとみなす上限を過ぎて、テストを終えるときに投げる。どの待ちが固まったかは、投げる前に残した失敗にある。
public struct WaitHang: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "待ちが固まったので、テストを終えました" }
}
