public import Testing

/// 条件を満たすまで待つ。待つ長さで打ち切らないので、負荷で遅れても落ちない。
/// 固まったときにテストの実行が止まらないよう、`hangLimit`を過ぎたら失敗を残して戻る。上限は、どれだけ混んでも条件を満たすまでにかからない長さにしてあり、待つ長さの見積もりではない。
/// 条件は、呼び出し元と同じアクター（メインアクターのテストならメインスレッド）で確かめる。
nonisolated(nonsending) public func waitUntil(
    _ condition: nonisolated(nonsending) () async throws -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + hangLimit
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("条件を満たさないまま、固まったとみなす上限を過ぎました", sourceLocation: sourceLocation)
            return
        }
        // メインスレッドで待つテストでも、待っている間にRunLoopを回して画面の更新を進める。
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// 待つのを打ち切って、固まったとみなすまでの長さ。
public let hangLimit: Duration = .seconds(60)
