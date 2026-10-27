import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 一覧が最初の読み込みで、読み込み中の表示から最初の行を出すときの見え方。アカウントを切り替えたときと起動したときに通る。
@Suite(.scratch)
@MainActor
struct FirstEntriesRevealTests {
    private func fadingCells(in harness: TimelineHarness) -> [UICollectionViewCell] {
        harness.collectionView.visibleCells.filter { $0.layer.animation(forKey: "opacity") != nil }
    }

    /// 読み込み中の表示から最初の行を出したら、見えている行を1コマで出さず、透明から浮かび上がらせる。
    @Test func firstEntriesFadeInFromLoading() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.viewController.setContentState(.loading)
        harness.window.layoutIfNeeded()

        harness.setStatuses(StatusFactory.make(count: 20, startingAt: 1_000))

        #expect(!harness.collectionView.visibleCells.isEmpty)
        #expect(fadingCells(in: harness).count == harness.collectionView.visibleCells.count)
    }

    /// 読み込み終えたあとの新着や描き直しでは、行を浮かび上がらせない。
    @Test func laterEntriesAreNotFaded() throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 20, startingAt: 1_000))

        harness.setStatuses(StatusFactory.make(count: 22, startingAt: 1_002))

        #expect(fadingCells(in: harness).isEmpty)
    }
}
