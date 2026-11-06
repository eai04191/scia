import SciaCore
import SwiftUI
import UIKit

/// 「タブに追加」で、足した項目のアイコンを、右上の「タブ」ボタンから切り替えタブの丸いボタンへ飛ばす。決まりはdocs/tabs.mdの「ユーザーのハッシュタグ」にある。
///
/// 浮かび上がる、弧を描いて吸い込まれる、着いて輪を広げる、の3段で動かす。値と飛ぶ間の計算は`TabAddFlightMotion`にある。
/// アイコンは2枚重ねのビューで動かす。内側が浮かび上がりのスプリング、外側が飛ぶ間の位置と倍率を持ち、見える大きさと不透明度は2つの掛け算になる。
/// 1枚のビューで飛ぶ間の大きさを上書きすると、スプリングが行き過ぎている途中で飛び始めたときに、大きさが段になって飛ぶため。
/// どれもウインドウの上に重ねたビューで、触れたものを受けないので、飛んでいる間も操作を止めない。
@MainActor
enum TabAddFlight {
    /// 飛ぶ間を刻むキーフレームの数。直線でつなぐので、120Hzの画面で飛ぶ間のコマ数（約66）を上回る数にする。
    private static let sampleCount = 90

    /// `image`を、ウインドウの座標の`source`の中心から、`destination`の中心へ飛ばす。
    static func fly(_ image: UIImage, from source: CGRect, to destination: UIView, in window: UIWindow, mediaTime: () -> CFTimeInterval = AppDependencies.mediaTime) {
        let motion = TabAddFlightMotion.self
        let target = destination.convert(destination.bounds, to: window)
        let start = CGPoint(x: source.midX, y: source.midY)
        let end = CGPoint(x: target.midX, y: target.midY)

        // 外側: 飛ぶ間の位置と倍率。
        let carrier = UIView(frame: CGRect(x: 0, y: 0, width: motion.iconSide, height: motion.iconSide))
        carrier.center = start
        carrier.isUserInteractionEnabled = false
        // 内側: 浮かび上がりのスプリング。
        let icon = UIImageView(image: image)
        icon.frame = carrier.bounds
        icon.layer.shadowColor = UIColor.black.cgColor
        icon.layer.shadowOpacity = 0.25
        icon.layer.shadowRadius = 6
        icon.layer.shadowOffset = CGSize(width: 0, height: 3)
        icon.transform = CGAffineTransform(scaleX: motion.popScaleFrom, y: motion.popScaleFrom)
        icon.alpha = motion.popOpacityFrom
        carrier.addSubview(icon)
        window.addSubview(carrier)

        // 1. ボタンから浮かび上がる。飛び始めても止めずに続ける。
        UIView.animate(.spring(duration: motion.popScaleSpring.duration, bounce: motion.popScaleSpring.bounce)) {
            icon.transform = CGAffineTransform(scaleX: motion.popScalePeak, y: motion.popScalePeak)
        }
        UIView.animate(.spring(duration: motion.popOpacitySpring.duration, bounce: motion.popOpacitySpring.bounce)) {
            icon.alpha = 1
        }

        // 2. 弧を描いて丸へ入る。式どおりに刻んだ値を直線でつなぐ。
        let samples = motion.samples(count: sampleCount, from: start, to: end)
        let keyTimes = (0...sampleCount).map { NSNumber(value: Double($0) / Double(sampleCount)) }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = samples.map { NSValue(cgPoint: $0.position) }
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = samples.map(\.scale)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = samples.map(\.opacity)
        for animation in [move, scale, fade] {
            animation.keyTimes = keyTimes
        }
        let group = CAAnimationGroup()
        group.animations = [move, scale, fade]
        group.duration = motion.flightDuration
        group.beginTime = mediaTime() + motion.departDelay
        // 飛び始めるまでは外側を動かさない。最初の値はどれも外側の今の値（飛び立つ点、倍率1）と同じ。
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        weak let destination = destination
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            carrier.removeFromSuperview()
            // 飛ぶ間に窓の大きさが変わって切り替えタブが動いたり消えたりしたら、もとの場所で触覚と輪を出さない。
            guard let destination, destination.window === window, destination.convert(destination.bounds, to: window) == target else { return }
            land(on: target, in: window)
        }
        carrier.layer.add(group, forKey: "flight")
        CATransaction.commit()
    }

    /// 3. 着いたら触覚を鳴らし、丸の上に輪を一度だけ広げる。
    private static func land(on target: CGRect, in window: UIWindow) {
        let motion = TabAddFlightMotion.self
        UINotificationFeedbackGenerator(view: window).notificationOccurred(.success)
        let ring = UIView(frame: target)
        ring.isUserInteractionEnabled = false
        ring.layer.cornerRadius = target.width / 2
        ring.layer.borderWidth = 3
        ring.layer.borderColor = window.tintColor.cgColor
        ring.backgroundColor = window.tintColor.withAlphaComponent(0.18)
        ring.transform = CGAffineTransform(scaleX: motion.ringScaleFrom, y: motion.ringScaleFrom)
        ring.alpha = motion.ringOpacityFrom
        window.addSubview(ring)
        UIView.animate(.spring(duration: motion.ringSpring.duration, bounce: motion.ringSpring.bounce)) {
            ring.transform = CGAffineTransform(scaleX: motion.ringScaleTo, y: motion.ringScaleTo)
            ring.alpha = 0
        } completion: {
            ring.removeFromSuperview()
        }
    }

    /// 記号で示す項目は、アクセントカラーの丸に白い記号を載せた画像にする。下地が暗い灰色だと黒い画面に溶け、記号の細い線だけが飛んで見えたため。
    /// 記号の色は塗りつぶしのボタンの文字と同じ決まりにし、モノトーンでは丸の反対の色にする。白い丸に白い記号が重ならないようにするため。
    /// 画像にすると色が変わらなくなるので、`traits`（ウインドウの見た目）で解決してから描く。
    static func symbolImage(_ name: String, tint: UIColor, traits: UITraitCollection) -> UIImage {
        let side = TabAddFlightMotion.iconSide
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let fill = tint.resolvedColor(with: traits)
        let foreground = UIColor.filledForeground(on: tint, traits: traits).resolvedColor(with: traits)
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            fill.setFill()
            UIBezierPath(ovalIn: bounds).fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.47, weight: .semibold)
            guard let symbol = UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(foreground, renderingMode: .alwaysOriginal) else { return }
            symbol.draw(at: CGPoint(x: bounds.midX - symbol.size.width / 2, y: bounds.midY - symbol.size.height / 2))
        }
    }
}
