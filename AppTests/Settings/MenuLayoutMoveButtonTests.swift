import SciaCore
import SciaTesting
import Testing
import UIKit
@testable import Scia

/// Macで、並びの行を、ドラッグの代わりに上下のボタンで動かす。どの端末でも、長押しのメニューから行を削除する。
@MainActor
@Suite(.failureState)
struct MenuLayoutMoveButtonTests {
    /// ボタンで動かすときは、ドラッグを切る。Macでは、ドラッグが離しても終わらないため。
    @Test func disablesDragging() throws {
        let screen = try Screen(layout: ComposeToolItem.defaultLayout)
        defer { screen.close() }

        #expect(!screen.collectionView.dragInteractionEnabled)
    }

    /// 「メニュー」のセクションの最後の行を下へ動かすと、「その他」のセクションの先頭に入る。ドラッグでセクションをまたいで動かせるのと揃える。
    @Test func movingDownFromLastRowCrossesMoreBoundary() throws {
        var saved: MenuLayout<ComposeToolItem>?
        let screen = try Screen(layout: ComposeToolItem.defaultLayout) { saved = $0 }
        defer { screen.close() }
        let last = try #require(screen.rowTitles(inSection: 0).last ?? nil)

        try screen.tap(SettingsTexts.MenuLayout.moveDown, inRowTitled: last)

        let elements = try #require(saved?.elements)
        let more = try #require(elements.firstIndex(of: .more))
        #expect(Self.title(of: elements[more + 1]) == last)
    }

    /// 端の行では、動けない向きのボタンを無効にする。動かした行のボタンも、新しい位置に合わせて変わる。
    @Test func disablesButtonsAtEnds() async throws {
        let screen = try Screen(layout: ComposeToolItem.defaultLayout)
        defer { screen.close() }
        let first = try #require(screen.rowTitles(inSection: 0).first ?? nil)

        #expect(try screen.button(SettingsTexts.MenuLayout.moveUp, inRowTitled: first).isEnabled == false)
        #expect(try screen.button(SettingsTexts.MenuLayout.moveDown, inRowTitled: first).isEnabled)

        try screen.tap(SettingsTexts.MenuLayout.moveDown, inRowTitled: first)

        try await waitUntil { (try? screen.button(SettingsTexts.MenuLayout.moveUp, inRowTitled: first).isEnabled) == true }
        let lastRow = try #require(screen.rowTitles(inSection: 1).last ?? nil)
        #expect(try screen.button(SettingsTexts.MenuLayout.moveDown, inRowTitled: lastRow).isEnabled == false)
    }

    /// 動かしたあと、ボタンの有効と無効は変えても、行のスイッチとボタンは作り直さない。作り直すと、入れ替わる動きが右端に出るため。
    @Test func keepsAccessoriesWhenMoving() async throws {
        let screen = try Screen(layout: ComposeToolItem.defaultLayout)
        defer { screen.close() }
        let titles = screen.rowTitles(inSection: 0).compactMap(\.self)
        let first = try #require(titles.first)
        let other = try #require(titles.last)
        let toggle = try screen.toggle(inRowTitled: other)
        let otherDown = try screen.button(SettingsTexts.MenuLayout.moveDown, inRowTitled: other)

        try screen.tap(SettingsTexts.MenuLayout.moveDown, inRowTitled: first)
        try await waitUntil { (try? screen.button(SettingsTexts.MenuLayout.moveUp, inRowTitled: first).isEnabled) == true }

        #expect(try screen.toggle(inRowTitled: other) === toggle)
        #expect(try screen.button(SettingsTexts.MenuLayout.moveDown, inRowTitled: other) === otherDown)
    }

    /// 区切り線を足して最後の行が端でなくなったら、その行の下ボタンを有効にする。行を足したり消したりしても、端が変わるため。
    @Test func updatesButtonsAfterAddingSeparator() async throws {
        let screen = try Screen(layout: ComposeToolItem.defaultLayout)
        defer { screen.close() }
        let last = try #require(screen.rowTitles(inSection: 1).last ?? nil)
        #expect(try screen.button(SettingsTexts.MenuLayout.moveDown, inRowTitled: last).isEnabled == false)

        try screen.select(SettingsTexts.MenuLayout.addSeparator)

        try await waitUntil { (try? screen.button(SettingsTexts.MenuLayout.moveDown, inRowTitled: last).isEnabled) == true }
    }

    /// 境目の後ろのセクションを出さない並びでは、最後の行を下へ動かせない。境目より後ろへ動かすと、画面から消えるため。
    @Test func cannotMovePastBoundaryWithoutMoreSection() throws {
        let screen = try Screen<PostActionBarItem>(layout: PostActionBarItem.defaultLayout)
        defer { screen.close() }
        let last = try #require(screen.rowTitles(inSection: 0).last ?? nil)

        #expect(try screen.button(SettingsTexts.MenuLayout.moveDown, inRowTitled: last).isEnabled == false)
    }

    /// 右クリックのメニューの「削除」で、スワイプと同じく、区切り線の行を外す。Macでは、マウスで行をスワイプできないため。
    @Test func menuDeletesSeparator() throws {
        var saved: MenuLayout<StatusMenuItem>?
        let screen = try Screen<StatusMenuItem>(layout: StatusMenuItem.defaultLayout) { saved = $0 }
        defer { screen.close() }
        let separators = StatusMenuItem.defaultLayout.elements.count { $0 == .separator }
        let elements = StatusMenuItem.defaultLayout.elements
        let separator = try #require(elements.firstIndex(of: .separator))
        try #require(separator < elements.firstIndex(of: .more) ?? elements.endIndex)
        let indexPath = IndexPath(item: separator, section: 0)

        let delete = try #require(screen.collectionViewController.rowMenu(at: indexPath).flatMap(Self.action(titled: SettingsTexts.delete)))
        delete.performWithSender(nil, target: nil)

        #expect(saved?.elements.count { $0 == .separator } == separators - 1)
    }

    /// ドラッグで並べ替える端末でも、長押しのメニューに「削除」を出す。遠くへ動かす項目は出さない。iPadにマウスをつないだときも、行をスワイプできないため。
    @Test func menuOffersOnlyDeleteWhenDragging() throws {
        let screen = try Screen<StatusMenuItem>(layout: StatusMenuItem.defaultLayout, movesWithButtons: false)
        defer { screen.close() }
        let separator = try #require(StatusMenuItem.defaultLayout.elements.firstIndex(of: .separator))

        let menu = try #require(screen.collectionViewController.rowMenu(at: IndexPath(item: separator, section: 0)))

        #expect(Self.action(titled: SettingsTexts.delete)(menu) != nil)
        #expect(Self.action(titled: SettingsTexts.MenuLayout.moveToTop)(menu) == nil)
        #expect(Self.action(titled: SettingsTexts.MenuLayout.moveToBottom)(menu) == nil)
    }

    /// スワイプで消せない項目には、「削除」を出さない。
    @Test func menuOmitsDeleteForUndeletableItem() throws {
        let screen = try Screen(layout: ComposeToolItem.defaultLayout)
        defer { screen.close() }

        let item = try #require(screen.rowTitles(inSection: 0).firstIndex { $0 != nil })

        let menu = try #require(screen.collectionViewController.rowMenu(at: IndexPath(item: item, section: 0)))
        #expect(Self.action(titled: SettingsTexts.delete)(menu) == nil)
    }

    private static func action(titled title: String) -> (UIMenu) -> UIAction? {
        { menu in
            menu.children.lazy.compactMap { element in
                (element as? UIAction).flatMap { $0.title == title ? $0 : nil } ?? (element as? UIMenu).flatMap(action(titled: title))
            }.first
        }
    }

    private static func title(of element: MenuLayout<ComposeToolItem>.Element) -> String? {
        if case .item(let item, _) = element { item.title } else { nil }
    }

    /// ボタンで動かす並びの画面を、すべての行が見える高さのウィンドウに出す。
    @MainActor
    private struct Screen<Item: MenuItemKind & MenuItemPresentable> {
        let window: UIWindow
        let collectionView: UICollectionView
        let collectionViewController: MenuLayoutViewController<Item>

        init(layout: MenuLayout<Item>, movesWithButtons: Bool = true, onChange: @escaping (MenuLayout<Item>) -> Void = { _ in }) throws {
            let controller = MenuLayoutViewController<Item>(
                layout: layout,
                image: { _ in nil },
                imageRevision: 0,
                options: [],
                actions: [],
                itemDeletion: nil,
                movesWithButtons: movesWithButtons,
                onChange: onChange
            )
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 2400)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            collectionView = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            collectionViewController = controller
        }


        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        /// 区切り線の行はnilにする。
        func rowTitles(inSection section: Int) -> [String?] {
            window.layoutIfNeeded()
            return (0..<collectionView.numberOfItems(inSection: section)).map { item in
                let cell = collectionView.cellForItem(at: IndexPath(item: item, section: section))
                return ((cell as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration)?.text
            }
        }

        func button(_ label: String, inRowTitled title: String) throws -> UIButton {
            try #require(Self.views(of: UIButton.self, in: try cell(titled: title)).first { $0.accessibilityLabel == label })
        }

        private func cell(titled title: String) throws -> UICollectionViewCell {
            window.layoutIfNeeded()
            return try #require(collectionView.visibleCells.first { cell in
                ((cell as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration)?.text == title
            })
        }

        /// 並びの下のボタンの行を選択する。
        func select(_ title: String) throws {
            window.layoutIfNeeded()
            let indexPath = try #require((0..<collectionView.numberOfSections).lazy.flatMap { section in
                (0..<collectionView.numberOfItems(inSection: section)).map { IndexPath(item: $0, section: section) }
            }.first { indexPath in
                ((collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration)?.text == title
            })
            collectionView.delegate?.collectionView?(collectionView, didSelectItemAt: indexPath)
        }

        func toggle(inRowTitled title: String) throws -> UISwitch {
            try #require(Self.views(of: UISwitch.self, in: try cell(titled: title)).first)
        }

        func tap(_ label: String, inRowTitled title: String) throws {
            try button(label, inRowTitled: title).sendActions(for: .primaryActionTriggered)
        }

        private static func views<View: UIView>(of type: View.Type, in view: UIView) -> [View] {
            view.subviews.flatMap { subview in (subview as? View).map { [$0] } ?? views(of: type, in: subview) }
        }
    }
}
