import SciaCore
import UIKit

/// トリミングの画面の、切り抜く範囲を変えるVoiceOverの要素。ピンチとドラッグの代わりに、上下のスワイプで一段ずつ拡大縮小し、
/// 操作（ローター）で範囲を上下左右へ動かす。投稿の画像とプロフィールの画像のトリミングで使う。
/// 読み上げる値は、拡大率と範囲の中央の位置。動かしたあとも、その値を読み上げる。
final class CropAccessibilityElement: UIAccessibilityElement {
    /// 範囲を変える前に呼ぶ。回転や枠の動きの途中なら、ここで止めて、見えている形に揃える。範囲はそのあとに読む。
    var willChange: () -> Void = {}
    /// 今の範囲。画像を読み込む前や、決められないときはnil。
    var viewport: () -> CropViewport? = { nil }
    /// 範囲を変える。倍率と位置をスクロールビューに当てる。
    var apply: (CropViewport) -> Void = { _ in }
    /// 枠の位置。入れ物の座標。枠は動かしたり大きさを変えたりするため、読むたびに決める。
    var frame: () -> CGRect = { .zero }

    override init(accessibilityContainer container: Any) {
        super.init(accessibilityContainer: container)
        accessibilityTraits = .adjustable
        accessibilityHint = "上下にスワイプして拡大と縮小をします。範囲は操作で動かします"
        accessibilityCustomActions = CropViewport.Direction.allCases.map { direction in
            UIAccessibilityCustomAction(name: direction.actionName) { [weak self] _ in
                guard let self, self.change({ $0.moved(direction) }) else { return false }
                // 操作のあとは値を読み上げないため、動かした先を知らせる。
                UIAccessibility.post(notification: .announcement, argument: self.accessibilityValue)
                return true
            }
        }
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { frame() }
        set {}
    }

    override var accessibilityValue: String? {
        get { viewport()?.accessibilityValue }
        set {}
    }

    override func accessibilityIncrement() {
        _ = change { $0.zoomed(by: CropViewport.zoomStep) }
    }

    override func accessibilityDecrement() {
        _ = change { $0.zoomed(by: 1 / CropViewport.zoomStep) }
    }

    /// 範囲を変えられたらtrue。端や倍率の限りで変わらなければfalseを返し、VoiceOverに端の音を鳴らさせる。
    private func change(_ transform: (CropViewport) -> CropViewport?) -> Bool {
        willChange()
        guard let current = viewport(), let next = transform(current) else { return false }
        apply(next)
        return true
    }
}

extension UIScrollView {
    /// `box`（このスクロールビューの見えている範囲の中の位置）に見えている範囲。
    func cropViewport(box: CGRect) -> CropViewport? {
        guard zoomScale > 0, contentSize.width > 0, contentSize.height > 0 else { return nil }
        return CropViewport(
            box: box,
            imageSize: CGSize(width: contentSize.width / zoomScale, height: contentSize.height / zoomScale),
            zoomScale: zoomScale,
            contentOffset: contentOffset,
            minimumZoomScale: minimumZoomScale,
            maximumZoomScale: maximumZoomScale
        )
    }

    /// `viewport`の倍率と位置を当てる。
    func apply(_ viewport: CropViewport) {
        zoomScale = viewport.zoomScale
        contentOffset = viewport.contentOffset
    }
}
