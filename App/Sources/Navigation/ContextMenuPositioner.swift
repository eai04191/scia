import os
import QuartzCore
import SciaCore
import UIKit

/// 表示中のcompactのコンテキストメニューを、決めた高さより下に出ないよう上へ移す。
///
/// compactの表示では、メニューの位置をUIKitが決め、ハイライトのプレビューを渡しても動かない。そこで、メニューを組む前に、ウィンドウの上に重なっている
/// `UICollectionView`を覚えておき（`prepare(in:)`）、出たあとに新しく現れた`UICollectionView`を、メニューの項目の一覧とみなす。
/// 祖先をたどり、親がウィンドウと同じ大きさで自身はそれより小さいビューを、メニュー全体とみなして`center`を動かす。候補が1つに決まらなければ、ほかの重なりを動かさないよう何もしない。
/// 開く動きの間も位置を保つよう、メニューを閉じ始めるまで毎コマ確かめる。
///
/// UIKitがメニューの項目を`UICollectionView`で並べ、メニュー全体のすぐ上にウィンドウと同じ大きさの入れ物を置くという、公開されていない作りに頼っている。
/// 作りが変わってメニューが見つからなくなったら、UIKitが決めた位置のまま出るだけで、メニューの操作は変わらない。見つからなかったことはログに残す。
/// 平坦なメニューで確かめた。サブメニューを開いたときと、メニューを開いたまま回転したときは確かめていない。
@MainActor
final class ContextMenuPositioner: NSObject {
    private weak var window: UIWindow?
    /// メニューを組む前から重なっていた`UICollectionView`。
    private var existingCollections: [ObjectIdentifier] = []
    /// メニューの下端に許す、いちばん下の位置（ウィンドウの座標）。
    private var bottomLimit: (@MainActor () -> CGFloat?)?
    private weak var menuView: UIView?
    private var displayLink: CADisplayLink?
    private var didFindMenu = false
    private let logger = SciaLog.logger(category: "contextMenuPosition")

    /// メニューを組む前（`configurationForMenuAtLocation`）に呼び、そのとき重なっている`UICollectionView`を覚える。
    func prepare(in window: UIWindow?) {
        stop()
        self.window = window
        existingCollections = window.map { overlayCollections(in: $0).map(ObjectIdentifier.init) } ?? []
    }

    /// メニューが出始めたら、閉じ始めるまで毎コマ、下端が`bottomLimit`より下なら上へ移す。
    func menuWillAppear(bottomLimit: @escaping @MainActor () -> CGFloat?) {
        displayLink?.invalidate()
        self.bottomLimit = bottomLimit
        didFindMenu = false
        let link = CADisplayLink(target: self, selector: #selector(updatePosition))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// メニューが閉じ始めたら止める。閉じる動きの間は、移した位置から閉じる。
    func menuWillEnd() {
        if displayLink != nil, !didFindMenu {
            logger.info("context menu to reposition was not found")
        }
        stop()
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        window = nil
        bottomLimit = nil
        menuView = nil
        existingCollections = []
    }

    /// 毎コマ呼ぶ。テストでは直接呼ぶ。
    @objc func updatePosition() {
        // 画面を閉じたりログアウトしたりして窓がなくなったら、閉じる知らせを待たずに止める。
        guard let window, let limit = bottomLimit?() else {
            stop()
            return
        }
        if menuView?.window !== window {
            menuView = findMenu(in: window)
        }
        guard let menu = menuView, let parent = menu.superview else { return }
        didFindMenu = true
        // UIKitはメニューの位置を変形（transform）でも決めるため、変形を含めた位置で下端を測る。変形を除いて`center`と大きさから測ると、移しすぎた。
        // 開く動きの間はUIKitが毎コマ大きさを変えるので、広がりきるまでの数コマは、UIKitが決めた位置から少しずつ上へずれて見える。
        let frame = menu.convert(menu.bounds, to: window)
        // 上端は安全領域の上端より上へ出さない。UIKitはメニューを自分が決めた位置に収まる高さにしているため、項目が多くて高いメニューを下端に合わせて移すと、
        // 先頭の項目がステータスバーの下に隠れ、中をスクロールしても見えなくなる。そのときは、下端が投稿欄より下に残っても、上端で止める。
        let headroom = max(0, frame.minY - window.safeAreaInsets.top)
        let delta = max(-headroom, min(0, limit - frame.maxY))
        guard delta < -1 / window.screen.scale else { return }
        let from = parent.convert(CGPoint.zero, from: window)
        let to = parent.convert(CGPoint(x: 0, y: delta), from: window)
        UIView.performWithoutAnimation { menu.center.y += to.y - from.y }
    }

    private func findMenu(in window: UIWindow) -> UIView? {
        let existing = Set(existingCollections)
        var candidates: [ObjectIdentifier: UIView] = [:]
        for collection in overlayCollections(in: window) where !existing.contains(ObjectIdentifier(collection)) {
            var child: UIView = collection
            while let parent = child.superview, parent !== window {
                if parent.bounds.size == window.bounds.size, child.bounds.width < window.bounds.width, child.bounds.height < window.bounds.height, !child.bounds.isEmpty {
                    candidates[ObjectIdentifier(child)] = child
                    break
                }
                child = parent
            }
        }
        guard candidates.count == 1 else { return nil }
        return candidates.values.first
    }

    /// アプリの画面の外に重なっている`UICollectionView`。メニューはアプリの画面の外に重ねて出すため、アプリの画面を包むビューはたどらない。
    private func overlayCollections(in window: UIWindow) -> [UICollectionView] {
        let root = window.rootViewController?.view
        return window.subviews
            .filter { overlay in root.map { !$0.isDescendant(of: overlay) } ?? true }
            .flatMap(collections(in:))
    }

    private func collections(in view: UIView) -> [UICollectionView] {
        var found = (view as? UICollectionView).map { [$0] } ?? []
        for child in view.subviews {
            found += collections(in: child)
        }
        return found
    }
}
