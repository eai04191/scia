import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 並びの画面で、表示のスイッチを切り替えたとき。
@MainActor
@Suite(.failureState)
struct MenuLayoutVisibilityTests {
    /// 表示中のタブが1つになったら、そのスイッチを切れなくし、2つに戻したら切れるようにする。ほかの行のスイッチは作り直さない。
    /// 作り直すと、入れ替わる動きが右端に出るため。
    @Test func lastVisibleTabSwitchFollowsVisibilityWithoutRecreating() throws {
        let layout = MenuLayout<TabItem>(elements: TabItem.defaultLayout.elements.map { element in
            if case .item(let item, _) = element { .item(item, isVisible: item == .home || item == .local) } else { element }
        })
        let controller = MenuLayoutViewController<TabItem>(
            layout: layout,
            image: { _ in nil },
            imageRevision: 0,
            options: [],
            actions: [],
            itemDeletion: nil
        ) { _ in }
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
        func toggle(_ item: TabItem) throws -> UISwitch {
            let cell = try #require(collectionView.visibleCells.first { cell in
                ((cell as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration)?.text == item.title
            })
            return try #require(Self.firstSwitch(in: cell))
        }
        let home = try toggle(.home)
        let local = try toggle(.local)
        #expect(home.isEnabled)

        local.isOn = false
        local.sendActions(for: .valueChanged)
        #expect(try toggle(.home) === home)
        #expect(!home.isEnabled)

        local.isOn = true
        local.sendActions(for: .valueChanged)
        #expect(home.isEnabled)
    }

    private static func firstSwitch(in view: UIView) -> UISwitch? {
        for subview in view.subviews {
            if let toggle = subview as? UISwitch ?? firstSwitch(in: subview) { return toggle }
        }
        return nil
    }
}
