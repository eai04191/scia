import Testing
@testable import Scia

/// 持ち主の画面が消えたら、スクロールの途中でも計測は残らない。
/// 残ると、スクロールしていない間も画面の更新を受け取り続け、処理の時間を測り続ける。
@MainActor
struct ScrollHitchMonitorTests {
    @Test func monitorIsReleasedWhenOwnerDisappearsWhileScrolling() {
        weak var observed: ScrollHitchMonitor?
        do {
            let monitor = ScrollHitchMonitor()
            monitor.start()
            observed = monitor
        }
        #expect(observed == nil)
    }
}
