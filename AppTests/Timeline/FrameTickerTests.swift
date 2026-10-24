import QuartzCore
import SciaTesting
import Testing
@testable import Scia

/// 毎フレーム経過時間を渡す部品が、持ち主がいなくなったときに止まることを確かめる。
@MainActor
struct FrameTickerTests {
    private final class Counter {
        var count = 0
    }

    private func waitUntilStopped(_ ticker: FrameTicker) async throws {
        try await waitUntil { !ticker.isRunning }
    }

    @Test func stopsWhenTickAsksToStop() async throws {
        let counter = Counter()
        let ticker = FrameTicker { _ in
            counter.count += 1
            return counter.count < 3
        }

        ticker.start()
        try await waitUntilStopped(ticker)

        #expect(!ticker.isRunning, "続けないと返したあとも動いています")
        #expect(counter.count == 3)
    }

    /// 動いている途中に画面が閉じられて持ち主が解放されたら、表示の時計を止める。
    /// 表示の時計は受け取り手を強く持つため、止めないと、持ち主がいないまま毎フレーム呼び続ける。
    @Test func stopsAfterOwnerIsReleased() async throws {
        var owner: Counter? = Counter()
        let ticker = FrameTicker { [weak owner] _ in
            guard let owner else { return false }
            owner.count += 1
            return true
        }
        ticker.start()
        // 持ち主がいる間は、毎フレーム呼ばれ続ける。
        try await waitUntil { (owner?.count ?? 0) >= 2 }
        #expect(ticker.isRunning)

        owner = nil
        try await waitUntilStopped(ticker)

        #expect(!ticker.isRunning, "持ち主がいなくなったあとも動いています")
    }
}
