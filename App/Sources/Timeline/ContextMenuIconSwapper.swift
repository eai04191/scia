import os
import QuartzCore
import SciaCore
import UIKit

/// 長押しのメニューを開いている間に届いた印を、メニューを組み直さずに描き替える。
///
/// UIKitには、表示中のメニューの項目の印を替える手段がない。`updateVisibleMenu`でメニューを取り替えると、メニューのスクロール位置が先頭に戻り、
/// 表示中の`UIAction`の`image`を書き換えても描き直されない。そこで、仮の印にそれだけの`UIImageAsset`を持たせ、
/// メニューを描いている`UIImageView`のうち、その資産の画像を持つものの画像を直接替える。
/// メニューの行はスクロールやサブメニューを開いたときに作り直されるため、開いている間は毎コマ探し直す。
///
/// UIKitが項目の印を`UIImageView`で描き、渡した画像（か、それから作った同じ資産の画像）を持つという、公開されていない作りに頼っている。
/// 作りが変わって見つからなくなっても、仮の印のまま残るだけで、メニューの操作は変わらない。
@MainActor
final class ContextMenuIconSwapper: NSObject {
    /// 画面の描き換えと同じ時間。テストでは差し替える。
    var mediaTime: () -> CFTimeInterval = AppDependencies.mediaTime
    /// 仮の印の資産ごとの、描き替える画像。
    private var icons: [ObjectIdentifier: Entry] = [:]
    private weak var window: UIWindow?
    private var displayLink: CADisplayLink?
    private var stats = Stats()
    private let logger = SciaLog.logger(category: "contextMenuIcon")

    /// 描き替えの目印にする仮の印。`symbolName`の記号を`side`ポイント四方に描き、メニューの文字色で塗られるようにする。
    func placeholder(symbolName: String, side: CGFloat, traitCollection: UITraitCollection) -> UIImage {
        let symbol = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            guard let symbol else { return }
            symbol.draw(at: CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2))
        }
        let asset = UIImageAsset()
        asset.register(drawn.withRenderingMode(.alwaysTemplate), with: UITraitCollection(displayScale: format.scale))
        icons[ObjectIdentifier(asset)] = Entry(asset: asset)
        return asset.image(with: traitCollection)
    }

    /// `placeholder`で作った仮の印を、`icon`に描き替える。メニューを開いていれば、次のコマで替える。
    func setIcon(_ icon: UIImage, for placeholder: UIImage) {
        guard let asset = placeholder.imageAsset, icons[ObjectIdentifier(asset)] != nil else {
            logger.debug("icon arrived for unknown placeholder")
            return
        }
        icons[ObjectIdentifier(asset)]?.icon = icon
    }

    /// メニューが出始めたら、閉じ始めるまで毎コマ描き替える。
    func menuWillAppear(in window: UIWindow?) {
        self.window = window
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(swapVisibleIcons))
        link.add(to: .main, forMode: .common)
        displayLink = link
        stats = Stats()
    }

    /// メニューが閉じ始めたら止め、仮の印を忘れる。閉じる動きの間は、描き替えた画像のまま残る。
    func menuWillEnd() {
        displayLink?.invalidate()
        displayLink = nil
        if stats.frames > 0 {
            logger.debug("context menu icon swap frames=\(self.stats.frames) views=\(self.stats.maxViews) avgMs=\(self.stats.totalSeconds / Double(self.stats.frames) * 1000, format: .fixed(precision: 3)) maxMs=\(self.stats.maxSeconds * 1000, format: .fixed(precision: 3)) swapped=\(self.stats.swapped)")
        }
        icons = [:]
    }

    @objc private func swapVisibleIcons() {
        guard let window, icons.values.contains(where: { $0.icon != nil }) else { return }
        let start = mediaTime()
        var visited = 0
        // メニューはアプリの画面（タブとその中の一覧）の外に重ねて出すため、アプリの画面を包むビューはたどらず、毎コマの手間を減らす。
        let root = window.rootViewController?.view
        for subview in window.subviews where root.map({ !$0.isDescendant(of: subview) }) ?? true {
            swapIcons(in: subview, visited: &visited)
        }
        for key in icons.keys where icons[key]?.icon != nil {
            icons[key]?.hasArrived = true
        }
        let elapsed = mediaTime() - start
        stats.frames += 1
        stats.totalSeconds += elapsed
        stats.maxSeconds = max(stats.maxSeconds, elapsed)
        stats.maxViews = max(stats.maxViews, visited)
    }

    private func swapIcons(in view: UIView, visited: inout Int) {
        visited += 1
        if let imageView = view as? UIImageView, let asset = imageView.image?.imageAsset,
           let entry = icons[ObjectIdentifier(asset)], let icon = entry.icon, imageView.image !== icon {
            if entry.hasArrived {
                imageView.image = icon
            } else {
                // 届いたときは、一覧のアイコン（`AvatarView`）と同じ長さで浮かび上がらせる。
                // 届いたあとにスクロールやサブメニューの開閉で作り直された行は、出てくるたびに揺らがないよう、すぐ替える。
                UIView.transition(with: imageView, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    imageView.image = icon
                }
            }
            stats.swapped += 1
        }
        for subview in view.subviews {
            swapIcons(in: subview, visited: &visited)
        }
    }

    private struct Entry {
        let asset: UIImageAsset
        /// 描き替える画像。まだ届いていなければnil。
        var icon: UIImage?
        /// 届いてから1コマ以上たった。浮かび上がらせるのは、届いた次のコマに描いている印だけにする。
        var hasArrived = false
    }

    /// 毎コマたどる手間。メニューを閉じるときにログに残す。
    private struct Stats {
        var frames = 0
        var totalSeconds: CFTimeInterval = 0
        var maxSeconds: CFTimeInterval = 0
        var maxViews = 0
        var swapped = 0
    }
}
