import SciaCore
import Testing
import UIKit
@testable import Scia

/// 並びの画面で、項目を左へスワイプして削除したときの行。
@MainActor
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
}
