import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 起点を隠す取り分は、隠す側がすべて返したときだけ起点を見せる。
@Suite(.scratch, .failureState)
@MainActor
struct ViewerConcealmentTests {
    /// 2つが隠していれば、片方が返しても隠したままにし、両方が返したら見せる。
    @Test func showsOnlyAfterEveryHolderReleases() {
        let tile = MediaTileView(store: .offline)
        let closing = ViewerConcealment(tile)
        let reopened = ViewerConcealment(tile)

        closing.release()
        #expect(tile.isConcealedForViewer, "片方が返しただけで見せました")

        reopened.release()
        #expect(!tile.isConcealedForViewer)
    }

    /// 返さないまま持ち主が手放しても、隠したままにならない。
    @Test func releasesWhenDroppedWithoutRelease() {
        let tile = MediaTileView(store: .offline)
        var concealment: ViewerConcealment? = ViewerConcealment(tile)
        #expect(tile.isConcealedForViewer)

        concealment = nil
        #expect(concealment == nil)
        #expect(!tile.isConcealedForViewer, "返さずに手放した取り分のせいで、隠したままです")
    }

    /// 2回返しても、ほかの側の取り分まで返さない。
    @Test func releasingTwiceKeepsOtherHolder() {
        let tile = MediaTileView(store: .offline)
        let first = ViewerConcealment(tile)
        let second = ViewerConcealment(tile)

        first.release()
        first.release()
        #expect(tile.isConcealedForViewer, "2回返すと、ほかの側の取り分まで返しました")
        second.release()
        #expect(!tile.isConcealedForViewer)
    }
}
