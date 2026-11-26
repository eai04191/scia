import SciaCore
import UIKit

extension UIView {
    /// UIKitのスプリングで、`root`の中をレイヤーのアニメーションとして止まるところまで動かし（`animateSpringToRest`）、動いている間は120Hzを頼む。動いている途中も、触れたものを受ける。
    /// 時間で決める動きは、これで書く。`bounce`が0なら、SwiftUIの`.smooth`と同じスプリングになる。
    /// SwiftUIのスプリングを`UIView.animate(_:changes:)`に渡すと、アプリの中で毎コマ値を入れて動かすので、120Hzで描ける画面でも60Hzで描かれた
    /// （iPhone 16 Proで、デバッグメニューのベンチマーク「スプリングのフレームレート」で確かめた）。
    /// レイヤーのアニメーションも、頼まないと、シートを出す動きが終わったあとの残りが60Hzで描かれた（iOS 27のシミュレーターで録り、コマごとの位置を比べて確かめた）。
    /// `duration`が0以下なら動かさずにすぐ変え、完了もすぐ呼ぶ。チューニングで時間を0にすると、0秒のスプリングになるため。
    /// `initialVelocity`は、動く距離を1としたときの、始めの速さ（1秒あたり）。
    /// `beginsFromCurrentState`がfalseなら、動く前の値（直前に動きの外で入れた値を含む）から動かす。trueなら、画面に見えている値から動かす。
    /// 直前に不透明度を0にしてから上げる動きでtrueにすると、まだ画面に出ていない0ではなく、画面に残っている前の不透明度から始まる（アプリのテストで確かめた）。
    /// 動いている値を途中ですぐ変えるときは、`removeAnimations(of:in:)`か`stopFading(at:)`で動きを外してから入れる。
    static func animateSpring(
        duration: TimeInterval,
        bounce: CGFloat = 0,
        delay: TimeInterval = 0,
        initialVelocity: CGFloat = 0,
        beginsFromCurrentState: Bool = false,
        in root: UIView,
        frameSource: any FrameSource = DisplayLinkFrameSource.shared,
        changes: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        guard duration > 0 else {
            UIView.performWithoutAnimation(changes)
            completion?()
            return
        }
        let highFrameRate = FrameTicker(source: frameSource) { _ in true }
        highFrameRate.start()
        animateSpringToRest(
            duration: duration,
            bounce: bounce,
            delay: delay,
            initialVelocity: initialVelocity,
            options: beginsFromCurrentState ? [.allowUserInteraction, .beginFromCurrentState] : [.allowUserInteraction],
            in: root,
            animations: changes
        ) { _ in
            highFrameRate.stop()
            completion?()
        }
    }

    /// `view`とその中の層から、`keyPaths`の値を動かしているアニメーション（止まるまでの続きを含む）を外す。`keyPaths`の`bounds`は`bounds.size`なども含む。
    /// 足し合わせるスプリングは、動きの外で値を入れても、残りが足されて動き続けるため、動いている値をすぐ変えるときは先に外す。
    static func removeAnimations(of keyPaths: Set<String>, in view: UIView) {
        removeAnimations(of: keyPaths, from: outermostLayer(of: view), includingSublayers: true)
    }

    /// 動かしている不透明度を止め、すぐ`alpha`にする。
    func stopFading(at alpha: CGFloat) {
        UIView.removeAnimations(of: ["opacity"], from: layer, includingSublayers: false)
        UIView.performWithoutAnimation {
            self.alpha = alpha
        }
    }

    private static func removeAnimations(of keyPaths: Set<String>, from layer: CALayer, includingSublayers: Bool) {
        for key in layer.animationKeys() ?? [] {
            guard let keyPath = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath,
                  keyPaths.contains(where: { keyPath == $0 || keyPath.hasPrefix($0 + ".") }) else { continue }
            layer.removeAnimation(forKey: key)
        }
        guard includingSublayers else { return }
        for sublayer in layer.sublayers ?? [] {
            removeAnimations(of: keyPaths, from: sublayer, includingSublayers: true)
        }
    }
}
