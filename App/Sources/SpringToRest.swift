import QuartzCore
import UIKit

extension UIView {
    /// `UIView.animate(springDuration:bounce: 0, ...)`と同じスプリングで、止まるところまで動かす。
    /// UIKitは、このスプリングを動く距離の約0.1%を残した時点で打ち切り、残りを最後のコマで飛ばす（時間を1.5秒に伸ばした投稿欄の閉じる動きで、
    /// 135pt動くバーが約2.2秒の時点で0.14pt手前から目標へ飛んだ。割合は時間によらないので、短い動きでも同じだけ飛ぶ）。
    /// そこで、`root`の中の層にこの動きで付いた、足し合わせるスプリングのそれぞれを、打ち切られたあとも同じスプリングで続ける。
    /// UIKitの動きはそのまま残し、`completion`は、UIKitの動きと続きの両方が終わってから呼ぶ。
    /// UIKitが打ち切った時点で呼ぶと、そこで複製を外して本物を見せる動き（投稿欄の本文や写真）で、複製と本物の続きの残りの差だけずれて見えるため。
    /// `completion`に渡すのは、UIKitの動きが終わりまで動いたか。
    /// 続きは、この動きで付いた距離をすべて足しても残りが1pxの`settledPixelFraction`より小さくなるまで動く。
    /// 入れ子の層の残りは足し合わさって見えるため、層ごとの残りでは決めない。
    /// 続きの途中で次の動きが始まっても、続きは見えている位置に足し合わさっているので、次の動きはそこから始まり、続きは0へ減って終わる。
    static func animateSpringToRest(duration: TimeInterval, delay: TimeInterval = 0, options: UIView.AnimationOptions = [], in root: UIView, animations: () -> Void, completion: ((Bool) -> Void)? = nil) {
        let top = outermostLayer(of: root)
        let before = springKeys(in: top)
        let ending = SpringRestEnding(completion: completion)
        UIView.animate(springDuration: duration, bounce: 0, initialSpringVelocity: 0, delay: delay, options: options, animations: animations) { finished in
            ending.springDidEnd(finished: finished)
        }
        let added = springKeys(in: top).flatMap { id, entry in
            entry.keys.subtracting(before[id]?.keys ?? []).compactMap { key in
                (entry.layer.animation(forKey: key) as? CASpringAnimation).flatMap { spring in
                    SpringDelta(spring.fromValue).map { (layer: entry.layer, key: key, spring: spring, from: $0) }
                }
            }
        }
        let total = added.reduce(0) { $0 + $1.from.magnitude }
        let pixel = 1 / max(root.traitCollection.displayScale, 1)
        let remainingLimit = total > 0 ? pixel * settledPixelFraction / total : 0
        SpringRestKeys.count += 1
        let prefix = "\(restKeyPrefix)\(SpringRestKeys.count)."
        // 続きを入れ子のトランザクションで足し、続きがすべて終わる（外れる）と終わりの処理を呼ばせる。続きがなければ、すぐ呼ばれる。
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            ending.restDidEnd()
        }
        if total > 0 {
            for animation in added {
                addRest(after: animation.spring, from: animation.from, to: animation.layer, key: prefix + animation.key, remainingLimit: remainingLimit)
            }
        }
        CATransaction.commit()
    }

    /// `view`を受け持つ層のうち、いちばん外側のもの。`view.layer`の外に、同じビューを受け持つ層が重なっていることがあり、
    /// そのときはビューの位置と大きさを外側の層が持つ（iOS 26の`UIVisualEffectView`では`_UIMultiLayer`が持っていた）。
    private static func outermostLayer(of view: UIView) -> CALayer {
        var layer = view.layer
        while let outer = layer.superlayer, outer.delegate === view {
            layer = outer
        }
        return layer
    }

    /// 打ち切られたあとに残してよい距離の、1pxに対する割合。
    private static let settledPixelFraction: CGFloat = 0.05
    /// 続きにつける名前の頭。続きには、さらに続きを付けない。
    /// 名前は呼ぶたびに変える。UIKitは外れた動きと同じ名前（`position`など）を次の動きに使うので、元の名前だけで続きを名付けると、
    /// 続きの途中に次の動きが始まったとき、前の続きを上書きして残りの分だけ飛ぶ。
    private static let restKeyPrefix = "springToRest."

    /// `layer`とその中の層の、足し合わせるスプリングの名前（続きは除く）。層ごとにまとめる。
    private static func springKeys(in layer: CALayer) -> [ObjectIdentifier: (layer: CALayer, keys: Set<String>)] {
        var result: [ObjectIdentifier: (layer: CALayer, keys: Set<String>)] = [:]
        func walk(_ layer: CALayer) {
            let keys = (layer.animationKeys() ?? []).filter { key in
                !key.hasPrefix(restKeyPrefix) && (layer.animation(forKey: key) as? CASpringAnimation)?.isAdditive == true
            }
            if !keys.isEmpty {
                result[ObjectIdentifier(layer)] = (layer, Set(keys))
            }
            layer.sublayers?.forEach(walk)
        }
        walk(layer)
        return result
    }

    /// `spring`を、打ち切られたあとも、残りの割合が`remainingLimit`より小さくなるまで続ける。続きは`key`と、その後ろに`.cancel`を付けた名前で足す。
    /// 止まるまでの長さにした同じスプリングを足し、元の長さの間だけ、逆向きの同じスプリングで打ち消す。
    /// 打ち切られる時点から始まる続きを1つ足す形にしないのは、途中から始めるために`timeOffset`をずらすと、Core Animationが動きの長さの中で時間を折り返し、違う位置を描いたため。
    /// 減衰しすぎず振動もしない（バウンス0の）スプリングだけを扱う。`animateSpringToRest`の動きはどれもバウンス0で、
    /// 中で別のスプリングを重ねたときは、止まるまでの長さを見積もる式が当てはまらないので、続けない。
    private static func addRest(after spring: CASpringAnimation, from: SpringDelta, to layer: CALayer, key: String, remainingLimit: CGFloat) {
        let omega = (spring.stiffness / spring.mass).squareRoot()
        guard omega > 0, abs(spring.damping - 2 * omega * spring.mass) <= 0.01 * spring.damping,
              let to = SpringDelta(spring.toValue ?? from.zero) else { return }
        // バウンス0のスプリングの残りの割合は(1 + (ω - v)t)e^(-ωt)。速さの向きによらない上限として、(1 + (ω + |v|)t)e^(-ωt)で見積もる。
        let velocity = abs(spring.initialVelocity)
        func remaining(at time: TimeInterval) -> CGFloat {
            (1 + (omega + velocity) * time) * exp(-omega * time)
        }
        var end = spring.duration
        while remaining(at: end) >= remainingLimit {
            end += 1.0 / 60
        }
        guard end > spring.duration,
              let whole = spring.copy() as? CASpringAnimation,
              let cancel = spring.copy() as? CASpringAnimation else { return }
        // 始まりの時間は元のまま写す。元が0なら、Core Animationが渡したときの同じ時間を3つに入れる。
        whole.delegate = nil
        whole.duration = end
        cancel.delegate = nil
        cancel.fromValue = from.negated
        cancel.toValue = to.negated
        layer.add(whole, forKey: key)
        layer.add(cancel, forKey: key + ".cancel")
    }
}

/// UIKitの動きと続きの両方が終わったら、`completion`を呼ぶ。
@MainActor
private final class SpringRestEnding {
    private let completion: ((Bool) -> Void)?
    private var springFinished: Bool?
    private var restEnded = false

    init(completion: ((Bool) -> Void)?) {
        self.completion = completion
    }

    func springDidEnd(finished: Bool) {
        springFinished = finished
        callIfEnded()
    }

    func restDidEnd() {
        restEnded = true
        callIfEnded()
    }

    private func callIfEnded() {
        guard restEnded, let springFinished else { return }
        completion?(springFinished)
    }
}

/// 続きの名前を呼ぶたびに変えるための数。
@MainActor
private enum SpringRestKeys {
    static var count = 0
}

/// 足し合わせるスプリングの、始まりと終わりの差。数、点、大きさだけを扱う。
private enum SpringDelta {
    case number(CGFloat)
    case point(CGPoint)
    case size(CGSize)

    init?(_ value: Any?) {
        if let number = value as? NSNumber {
            self = .number(CGFloat(number.doubleValue))
            return
        }
        guard let value = value as? NSValue else { return nil }
        let type = String(cString: value.objCType)
        if type == String(cString: NSValue(cgPoint: .zero).objCType) {
            self = .point(value.cgPointValue)
        } else if type == String(cString: NSValue(cgSize: .zero).objCType) {
            self = .size(value.cgSizeValue)
        } else {
            return nil
        }
    }

    /// 成分のうち最も大きいものの大きさ。
    var magnitude: CGFloat {
        switch self {
        case let .number(value): abs(value)
        case let .point(point): max(abs(point.x), abs(point.y))
        case let .size(size): max(abs(size.width), abs(size.height))
        }
    }

    var negated: Any {
        switch self {
        case let .number(value): NSNumber(value: Double(-value))
        case let .point(point): NSValue(cgPoint: CGPoint(x: -point.x, y: -point.y))
        case let .size(size): NSValue(cgSize: CGSize(width: -size.width, height: -size.height))
        }
    }

    /// 同じ種類の0。終わりの値がないときに使う。
    var zero: Any {
        switch self {
        case .number: NSNumber(value: 0)
        case .point: NSValue(cgPoint: .zero)
        case .size: NSValue(cgSize: .zero)
        }
    }
}
