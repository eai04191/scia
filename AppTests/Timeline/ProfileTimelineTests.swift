import SciaCore
import Testing
import UIKit
@testable import Scia

/// プロフィールを開いて戻る操作と、プロフィールのヘッダーの伸び縮みで、読んでいる位置が動かないことを確かめる。
@MainActor
@Suite(.serialized)
struct ProfileTimelineTests {
    private var tolerance: CGFloat { 1 / max(UITraitCollection.current.displayScale, 1) }

    @Test(arguments: [0.0, 0.4, 1.0])
    func openingAndClosingProfileKeepsAnchorPosition(scrollFraction: CGFloat) throws {
        let harness = try TimelineHarness()
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 60, startingAt: 1_000))
        harness.scroll(toFraction: scrollFraction)
        let anchor = try #require(harness.viewController.currentAnchor())
        let before = try #require(harness.windowMinY(of: anchor.id))
        let navigation = try #require(harness.viewController.navigationController)

        let profile = TimelineViewController(texts: .profile, refresh: {}, tuning: harness.tuning, emojiImages: .offline, mediaImages: .offline, avatarImages: .offline, settings: .isolated())
        profile.headerView = UIView()
        navigation.pushViewController(profile, animated: false)
        navigation.view.layoutIfNeeded()
        navigation.popViewController(animated: false)
        navigation.view.layoutIfNeeded()

        let after = try #require(harness.windowMinY(of: anchor.id), "戻ったあとに基準の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
    }

    /// ヘッダーを読み終えて下の投稿を読んでいる間に、プロフィールを読み直してヘッダーの高さが変わっても、読んでいる投稿は動かさない。
    @Test func headerGrowingBelowScrollKeepsAnchorPosition() throws {
        let header = UIView()
        let height = header.heightAnchor.constraint(equalToConstant: 300)
        height.isActive = true
        let harness = try TimelineHarness(headerView: header)
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 60, startingAt: 1_000))
        harness.scroll(toFraction: 0.5)
        let anchor = try #require(harness.viewController.currentAnchor())
        let before = try #require(harness.windowMinY(of: anchor.id))

        height.constant = 500
        harness.viewController.headerDidChangeSize()

        let after = try #require(harness.windowMinY(of: anchor.id), "ヘッダーが伸びたあとに基準の投稿が画面外へ出ました")
        #expect(abs(after - before) <= tolerance, "基準の投稿が\(after - before)pt動きました")
    }

    /// ヘッダーが見えている間は、ヘッダーが伸びた分だけ下の投稿が下がる。
    @Test func headerGrowingAtTopPushesStatusesDown() throws {
        let header = UIView()
        let height = header.heightAnchor.constraint(equalToConstant: 300)
        height.isActive = true
        let harness = try TimelineHarness(headerView: header)
        defer { harness.tearDown() }
        let statuses = StatusFactory.make(count: 60, startingAt: 1_000)
        harness.setStatuses(statuses)
        let first = try #require(statuses.first.map { TimelineEntry.ID.status($0.id) })
        let before = try #require(harness.windowMinY(of: first))

        height.constant = 350
        harness.viewController.headerDidChangeSize()

        let after = try #require(harness.windowMinY(of: first))
        #expect(abs(after - before - 50) <= tolerance, "先頭の投稿が\(after - before)pt動きました")
    }

    /// ヘッダーが画面の途中にあるときにタブを切り替えると、両方の一覧にある投稿を基準に位置を保ってしまい、
    /// 上に足された固定された投稿の分だけヘッダーとタブが押し上げられていた。タブは押した場所に残し、中身だけを差し替える。
    @Test func switchingTabKeepsHeaderPosition() throws {
        let header = UIView()
        header.heightAnchor.constraint(equalToConstant: 600).isActive = true
        let harness = try TimelineHarness(headerView: header)
        defer { harness.tearDown() }
        let posts = StatusFactory.make(count: 40, startingAt: 1_000)
        let media = Array(posts.prefix(20))
        let pinned = StatusFactory.make(count: 3, startingAt: 2_000)
        harness.viewController.setEntries(media.map(TimelineEntry.status))
        harness.collectionView.layoutIfNeeded()
        // ヘッダーの下端が画面の半分あたりに来るまでスクロールする。
        harness.collectionView.contentOffset.y = -harness.collectionView.adjustedContentInset.top + 300
        harness.collectionView.layoutIfNeeded()
        let before = header.convert(header.bounds, to: nil).minY

        harness.viewController.setEntries(pinned.map(TimelineEntry.pinned) + posts.map(TimelineEntry.status), keepsOffset: true)
        harness.collectionView.layoutIfNeeded()

        let after = header.convert(header.bounds, to: nil).minY
        #expect(abs(after - before) <= tolerance, "ヘッダーが\(after - before)pt動きました")
    }

    /// 固定された投稿の棚はタブの下にあり、「投稿」の一覧でだけ出す。タブを切り替えて棚が出たり消えたりしても、ヘッダーとタブは押した場所に残す。
    @Test(arguments: [200.0, -200.0])
    func pinnedShelfChangingWithTabKeepsHeaderPosition(heightChange: CGFloat) throws {
        let header = UIView()
        let height = header.heightAnchor.constraint(equalToConstant: 600)
        height.isActive = true
        let harness = try TimelineHarness(headerView: header)
        defer { harness.tearDown() }
        let posts = StatusFactory.make(count: 40, startingAt: 1_000)
        harness.viewController.setEntries(posts.map(TimelineEntry.status))
        harness.collectionView.layoutIfNeeded()
        // ヘッダーの下端が画面の半分あたりに来るまでスクロールする。
        harness.collectionView.contentOffset.y = -harness.collectionView.adjustedContentInset.top + 300
        harness.collectionView.layoutIfNeeded()
        let before = header.convert(header.bounds, to: nil).minY

        // プロフィールは、棚を変えてヘッダーの高さを測り直してから、切り替えた一覧を入れる。
        height.constant += heightChange
        harness.viewController.headerDidChangeSize()
        let middle = header.convert(header.bounds, to: nil).minY
        #expect(abs(middle - before) <= tolerance, "高さを測り直した時点でヘッダーが\(middle - before)pt動きました")
        harness.viewController.setEntries(Array(posts.prefix(20)).map(TimelineEntry.status), keepsOffset: true)
        harness.collectionView.layoutIfNeeded()

        let after = header.convert(header.bounds, to: nil).minY
        #expect(abs(after - before) <= tolerance, "ヘッダーが\(after - before)pt動きました")
        // 一覧が持つヘッダーの高さが、測り直した高さになっている。見積もりの高さに戻ったままだと、ヘッダーが画面外と見なされて消える。
        let attributes = harness.collectionView.layoutAttributesForSupplementaryElement(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: 0))
        #expect(abs((attributes?.frame.height ?? 0) - height.constant) <= tolerance, "一覧のヘッダーの高さが\(attributes?.frame.height ?? 0)ptでした")
    }

    /// 一番上から引っぱっている間に、画像やアカウントが届いてヘッダーの高さが変わっても、引っぱった分を保つ。上端に詰めると、指を離す前にヘッダーが跳ぶ。
    @Test func headerChangingWhilePulledKeepsPull() throws {
        let header = UIView()
        let height = header.heightAnchor.constraint(equalToConstant: 600)
        height.isActive = true
        let harness = try TimelineHarness(headerView: header)
        defer { harness.tearDown() }
        harness.setStatuses(StatusFactory.make(count: 40, startingAt: 1_000))
        let top = -harness.collectionView.adjustedContentInset.top
        harness.collectionView.contentOffset.y = top - 80
        harness.collectionView.layoutIfNeeded()

        height.constant = 700
        harness.viewController.headerDidChangeSize()

        let pulled = top - harness.collectionView.contentOffset.y
        #expect(abs(pulled - 80) <= tolerance, "引っぱった分が\(pulled)ptになりました")
    }
}
