import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// 並びの画面で、項目を左へスワイプして削除したときの行。
@MainActor
@Suite(.failureState)
struct MenuLayoutDeletionTests {
    private static let bob = TabItem.profile(accountID: "2", acct: "bob")

    /// スワイプで削除を頼んだ項目が並びから外れて届いたら、残る行は作り直さず、外れた行だけを閉じる。使う人の操作で消える行を動きで閉じるため。
    /// ほかの変化は、これまでどおり行を作り直す。
    @Test func deletedItemRowClosesWhileOtherRowsStay() throws {
        let layout = MenuLayout<TabItem>(elements: [.item(.home, isVisible: true), .item(Self.bob, isVisible: true), .more, .item(.local, isVisible: true)])
        var deleted: [TabItem] = []
        let controller = MenuLayoutViewController<TabItem>(
            layout: layout,
            image: { _ in nil },
            imageRevision: 0,
            options: [],
            actions: [],
            itemDeletion: MenuLayoutItemDeletion(canDelete: \.isUserAdded) { deleted.append($0) }
        ) { _ in }
        let before = controller.rowIDs
        let bobIndex = try #require(layout.elements.firstIndex(of: .item(Self.bob, isVisible: true)))

        controller.requestDeletion(of: Self.bob)
        controller.update(MenuLayout(elements: layout.elements.filter { $0 != .item(Self.bob, isVisible: true) }))

        #expect(deleted == [Self.bob])
        var expected = before
        expected.remove(at: bobIndex)
        #expect(controller.rowIDs == expected)

        controller.update(MenuLayout(elements: [.item(.local, isVisible: true), .more, .item(.home, isVisible: true)]))
        #expect(Set(controller.rowIDs).isDisjoint(with: expected))
    }

    /// 削除で表示中のタブが1つになったら、残った行は作り直さなくても、そのスイッチを切れなくする。タブバーを空にさせないため。
    @Test func lastVisibleTabSwitchIsDisabledAfterDeletion() async throws {
        let others = TabItem.defaultLayout.elements.map { element -> MenuLayout<TabItem>.Element in
            if case .item(let item, _) = element { .item(item, isVisible: item == .home) } else { element }
        }
        let layout = MenuLayout<TabItem>(elements: [.item(Self.bob, isVisible: true)] + others)
        let controller = MenuLayoutViewController<TabItem>(
            layout: layout,
            image: { _ in nil },
            imageRevision: 0,
            options: [],
            actions: [],
            itemDeletion: MenuLayoutItemDeletion(canDelete: \.isUserAdded) { _ in }
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
        let homeSwitch = {
            window.layoutIfNeeded()
            let cell = collectionView.visibleCells.first { cell in
                ((cell as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration)?.text == TabItem.home.title
            }
            return cell.flatMap { Self.firstSwitch(in: $0) }
        }
        #expect(homeSwitch()?.isEnabled == true)

        controller.requestDeletion(of: Self.bob)
        controller.update(MenuLayout(elements: layout.elements.filter { $0 != .item(Self.bob, isVisible: true) }))

        try await waitUntil { homeSwitch()?.isEnabled == false }
    }

    /// 表示中の最後のタブを消し、ホームを表示にした並びが届いても、残る行は作り直さず、外れた行だけを閉じる。ホームのスイッチは入れる。
    @Test func deletingLastVisibleTabKeepsRowsAndTurnsHomeOn() async throws {
        let others = TabItem.defaultLayout.elements.map { element -> MenuLayout<TabItem>.Element in
            if case .item(let item, _) = element { .item(item, isVisible: false) } else { element }
        }
        let layout = MenuLayout<TabItem>(elements: [.item(Self.bob, isVisible: true)] + others)
        let controller = MenuLayoutViewController<TabItem>(
            layout: layout,
            image: { _ in nil },
            imageRevision: 0,
            options: [],
            actions: [],
            itemDeletion: MenuLayoutItemDeletion(canDelete: \.isUserAdded) { _ in }
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
        let before = controller.rowIDs

        controller.requestDeletion(of: Self.bob)
        controller.update(MenuLayout(elements: others.map { $0 == .item(.home, isVisible: false) ? .item(.home, isVisible: true) : $0 }))

        #expect(controller.rowIDs == Array(before.dropFirst()))
        try await waitUntil {
            window.layoutIfNeeded()
            let cell = collectionView.visibleCells.first { cell in
                ((cell as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration)?.text == TabItem.home.title
            }
            return cell.flatMap { Self.firstSwitch(in: $0) }?.isOn == true
        }
    }

    private static func firstSwitch(in view: UIView) -> UISwitch? {
        for subview in view.subviews {
            if let toggle = subview as? UISwitch ?? firstSwitch(in: subview) { return toggle }
        }
        return nil
    }
}
