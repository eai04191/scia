import QuartzCore
import UIKit

/// UIKitの`UIView.animate(withDuration:delay:usingSpringWithDamping:initialSpringVelocity:)`が使うばね。
/// 係数（質量・硬さ・減衰）は、UIKit自身に一度アニメーションを作らせて読む。UIKitが時間と減衰比から係数を決める式は公開されていないため。
/// 同じ係数の進み具合を自分で計算し、キーフレームのアニメーションにして、UIKitのばねと同じ動きを、UIKitで動かせない値（背景に合わせた中身の位置など）にも当てる。
struct UIKitSpring: Equatable {
    let mass: Double
    let stiffness: Double
    let damping: Double
    /// UIKitがアニメーションにする時間。ばねはこの時間でほぼ止まる。
    let duration: TimeInterval

    /// `duration`と`dampingRatio`でUIKitが作るばね。読めなかったら止める。UIKitの作りが変わって読めなくなったことに、すぐ気づけるようにするため。
    @MainActor
    static func make(duration: TimeInterval, dampingRatio: CGFloat) -> UIKitSpring {
        let key = Key(duration: duration, dampingRatio: dampingRatio)
        if let cached = cache[key] { return cached }
        let probe = UIView()
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: dampingRatio, initialSpringVelocity: 0, options: []) {
            probe.alpha = 0.5
        }
        guard let animation = probe.layer.animation(forKey: "opacity") as? CASpringAnimation else {
            preconditionFailure("UIKitのばねのアニメーションを読めません")
        }
        let spring = UIKitSpring(mass: animation.mass, stiffness: animation.stiffness, damping: animation.damping, duration: animation.duration)
        probe.layer.removeAllAnimations()
        cache[key] = spring
        return spring
    }

    private struct Key: Hashable {
        let duration: TimeInterval
        let dampingRatio: CGFloat
    }

    @MainActor private static var cache: [Key: UIKitSpring] = [:]

    /// 経過時間`time`での進み具合。0から始まり1に落ち着く。弾む場合は1を超えることがある。
    /// 初速0で、残りの割合を1から0へ向かう減衰振動として解く（`CASpringAnimation`と同じ運動方程式）。
    func progress(at time: TimeInterval) -> Double {
        guard time > 0 else { return 0 }
        guard time < duration else { return 1 }
        let naturalFrequency = (stiffness / mass).squareRoot()
        let ratio = damping / (2 * (stiffness * mass).squareRoot())
        let remaining: Double
        if ratio < 1 {
            let dampedFrequency = naturalFrequency * (1 - ratio * ratio).squareRoot()
            remaining = exp(-ratio * naturalFrequency * time)
                * (cos(dampedFrequency * time) + ratio * naturalFrequency / dampedFrequency * sin(dampedFrequency * time))
        } else if ratio == 1 {
            remaining = exp(-naturalFrequency * time) * (1 + naturalFrequency * time)
        } else {
            let root = (ratio * ratio - 1).squareRoot()
            let fast = -naturalFrequency * (ratio + root)
            let slow = -naturalFrequency * (ratio - root)
            remaining = (fast * exp(slow * time) - slow * exp(fast * time)) / (fast - slow)
        }
        return 1 - remaining
    }
}
