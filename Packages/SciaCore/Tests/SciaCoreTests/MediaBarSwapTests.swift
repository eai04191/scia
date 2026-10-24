import SciaCore
import Testing

struct MediaBarSwapTests {
    /// 閉じ始めはすべて手前、着地ではすべて一覧の中の複製に見せる。
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

    /// 開き始めはサムネイルと同じくすべて一覧の中の複製、開ききるとすべて手前に見せる。
    @Test func openingStartsBehindBarsAndEndsInFront() {
        let start = MediaBarSwap.opening(progress: 0, handoffEnd: 0.3, overlapFadeStart: 0.7)
        #expect(start == MediaBarSwap(handoff: 1, overlapOpacity: 0))
        let end = MediaBarSwap.opening(progress: 1, handoffEnd: 0.3, overlapFadeStart: 0.7)
        #expect(end == .front)
    }

    /// 受け渡しを終えてから、バーと重なる部分を手前へ入れ替える。
    @Test func openingHandsOffBeforeSwappingOverlap() {
        let middle = MediaBarSwap.opening(progress: 0.5, handoffEnd: 0.3, overlapFadeStart: 0.7)
        #expect(middle == MediaBarSwap(handoff: 0, overlapOpacity: 0))
    }

    /// バウンスして1を超えても、手前に見せたままにする。
    @Test func openingStaysInFrontWhileOvershooting() {
        #expect(MediaBarSwap.opening(progress: 1.05, handoffEnd: 0.3, overlapFadeStart: 0.7) == .front)
    }

    /// 受け渡しを終える進み具合が0なら、開き始めから手前に見せる。
    @Test func openingWithoutHandoff() {
        #expect(MediaBarSwap.opening(progress: 0, handoffEnd: 0, overlapFadeStart: 0.7).handoff == 0)
    }

    /// つかんだあとは、そのときの状態からすべて手前へ寄せる。
    @Test func convergingToFront() {
        let swap = MediaBarSwap(handoff: 0.75, overlapOpacity: 0.25)
        #expect(swap.converging(toFront: 0) == swap)
        #expect(swap.converging(toFront: 0.5) == MediaBarSwap(handoff: 0.375, overlapOpacity: 0.625))
        #expect(swap.converging(toFront: 1) == .front)
    }
}
