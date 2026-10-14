import SciaCore
import Testing

struct MediaBarSwapTests {
    /// 閉じ始めはすべて手前、着地ではすべて一覧の中の写しに見せる。
    @Test func closingStartsInFrontAndLandsBehindBars() {
        let start = MediaBarSwap.closing(progress: 0, handoffStart: 0.7, overlapFadeEnd: 0.3)
        #expect(start == .front)
        let end = MediaBarSwap.closing(progress: 1, handoffStart: 0.7, overlapFadeEnd: 0.3)
        #expect(end == MediaBarSwap(handoff: 1, overlapOpacity: 0))
    }

    /// バーと重なる部分は入れ替え終える進み具合までに奥へ移し、受け渡しはそれより前には始めない。
    @Test func closingSwapsOverlapBeforeHandoff() {
        let middle = MediaBarSwap.closing(progress: 0.5, handoffStart: 0.7, overlapFadeEnd: 0.3)
        #expect(middle == MediaBarSwap(handoff: 0, overlapOpacity: 0))
    }

    /// 開く途中から閉じたときは、そのときの濃さから薄くする。
    @Test func closingStartsFromGivenOverlapOpacity() {
        let start = MediaBarSwap.closing(progress: 0, handoffStart: 0.7, overlapFadeEnd: 0.3, startOverlapOpacity: 0.4)
        #expect(start.overlapOpacity == 0.4)
    }

    /// 受け渡し始めが1なら、着地の瞬間に切り替える。
    @Test func closingHandsOffAtLandingWhenStartIsOne() {
        #expect(MediaBarSwap.closing(progress: 0.99, handoffStart: 1, overlapFadeEnd: 0.3).handoff == 0)
        #expect(MediaBarSwap.closing(progress: 1, handoffStart: 1, overlapFadeEnd: 0.3).handoff == 1)
    }
}
