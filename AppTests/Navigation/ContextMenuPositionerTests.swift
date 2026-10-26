import Testing
import UIKit
@testable import Scia

/// UIKitのメニューと同じ並び（ウィンドウと同じ大きさの入れ物の中に、項目の一覧を持つメニュー全体）を組んで、位置を直す決まりを確かめる。
/// UIKitの作りそのものが変わったことは、ここでは確かめられない。
@MainActor
struct ContextMenuPositionerTests {
    @MainActor
    private struct Harness {
        let window: UIWindow
        /// アプリの画面の外に重ねた、ウィンドウと同じ大きさの入れ物。
        let overlay: UIView

        init() throws {
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "テストのホストアプリにウィンドウシーンがありません"
            )
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            overlay = UIView(frame: window.bounds)
            window.addSubview(overlay)
        }

        /// 項目の一覧を持つメニューを、`frame`（ウィンドウの座標）に置く。
        @discardableResult
        func addMenu(frame: CGRect) -> UIView {
            let menu = UIView(frame: frame)
            let list = UICollectionView(frame: menu.bounds, collectionViewLayout: UICollectionViewFlowLayout())
            menu.addSubview(list)
            overlay.addSubview(menu)
            return menu
        }

        func frame(of view: UIView) -> CGRect {
            view.convert(view.bounds, to: window)
        }
    }

    /// 出たメニューの下端が決めた高さより下なら、下端がその高さになるまで上へ移す。
    @Test func movesNewMenuUpToBottomLimit() throws {
        let harness = try Harness()
        let positioner = ContextMenuPositioner()
        positioner.prepare(in: harness.window)
        let menu = harness.addMenu(frame: CGRect(x: 130, y: 640, width: 250, height: 190))
        positioner.menuWillAppear { 783 }
        positioner.updatePosition()
        #expect(harness.frame(of: menu).maxY == 783)
        positioner.menuWillEnd()
    }

    /// 下端がすでに決めた高さより上なら、動かさない。
    @Test func leavesMenuAboveBottomLimit() throws {
        let harness = try Harness()
        let positioner = ContextMenuPositioner()
        positioner.prepare(in: harness.window)
        let menu = harness.addMenu(frame: CGRect(x: 130, y: 500, width: 250, height: 190))
        positioner.menuWillAppear { 783 }
        positioner.updatePosition()
        #expect(harness.frame(of: menu).minY == 500)
        positioner.menuWillEnd()
    }

    /// 高いメニューは、上端が安全領域の上端に届いたら止める。先頭の項目が画面の上に隠れないようにするため。
    @Test func stopsAtSafeAreaTop() throws {
        let harness = try Harness()
        let positioner = ContextMenuPositioner()
        positioner.prepare(in: harness.window)
        let top = harness.window.safeAreaInsets.top
        let menu = harness.addMenu(frame: CGRect(x: 130, y: top + 10, width: 250, height: 820))
        positioner.menuWillAppear { 783 }
        positioner.updatePosition()
        #expect(harness.frame(of: menu).minY == top)
        positioner.menuWillEnd()
    }

    /// メニューを組む前から重なっていた一覧は、メニューとみなさず動かさない。
    @Test func ignoresListsThatExistedBeforeMenu() throws {
        let harness = try Harness()
        let positioner = ContextMenuPositioner()
        let existing = harness.addMenu(frame: CGRect(x: 0, y: 600, width: 250, height: 250))
        positioner.prepare(in: harness.window)
        positioner.menuWillAppear { 783 }
        positioner.updatePosition()
        #expect(harness.frame(of: existing).minY == 600)
        positioner.menuWillEnd()
    }

    /// 新しく現れた一覧が2つあれば、どちらがメニューか決められないので、どちらも動かさない。
    @Test func leavesMenusWhenAmbiguous() throws {
        let harness = try Harness()
        let positioner = ContextMenuPositioner()
        positioner.prepare(in: harness.window)
        let first = harness.addMenu(frame: CGRect(x: 0, y: 640, width: 200, height: 190))
        let second = harness.addMenu(frame: CGRect(x: 200, y: 640, width: 200, height: 190))
        positioner.menuWillAppear { 783 }
        positioner.updatePosition()
        #expect(harness.frame(of: first).minY == 640)
        #expect(harness.frame(of: second).minY == 640)
        positioner.menuWillEnd()
    }
}
