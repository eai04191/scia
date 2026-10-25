import Dispatch
import QuartzCore
import SciaTesting
import Testing

@MainActor
struct LayerClockTests {
    /// メインキューの処理が次の処理を積んでいくとき、1コマ進めたら、積まれた処理を最後まで流し終えてから戻る。
    /// 途中で戻ると、残った処理が次のコマに持ち越され、状態を確かめる時点や次の動きを始める時点がずれる。
    @Test func advanceWaitsForChainedMainQueueWork() async throws {
        let clock = LayerClock(freezing: CALayer())
        let counter = Counter()
        Self.enqueue(remaining: 6, counting: counter)

        try await clock.advance(by: LayerClock.frame)

        #expect(counter.value == 6)
    }

    private static func enqueue(remaining: Int, counting counter: Counter) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                counter.value += 1
                if remaining > 1 { enqueue(remaining: remaining - 1, counting: counter) }
            }
        }
    }
}

@MainActor
private final class Counter {
    var value = 0
}
