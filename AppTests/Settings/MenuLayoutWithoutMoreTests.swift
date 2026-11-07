import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 「その他」の境目を持たない並び（アクションバー）の並びの画面。境目の後ろの節は出さない。
@MainActor
struct MenuLayoutWithoutMoreTests {
    /// 並べ替えると、1つの節の中の順で並びを保存する。
    @Test func reorderingSavesOrder() throws {
        var saved: MenuLayout<PostActionBarItem>?
        let controller = MenuLayoutViewController<PostActionBarItem>(
            layout: PostActionBarItem.defaultLayout,
            image: { _ in nil },
            imageRevision: 0,
            options: [],
            actions: [],
            itemDeletion: nil
        ) { saved = $0 }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 2400)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let collectionView = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)

        collectionView.dataSource?.collectionView?(collectionView, moveItemAt: IndexPath(item: 0, section: 0), to: IndexPath(item: 1, section: 0))

        #expect(saved?.actionBarItems.prefix(2) == [.status(.reblog), .status(.reply)])
    }
}
