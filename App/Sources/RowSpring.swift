import QuartzCore

extension CASpringAnimation {
    /// 行を動かすスプリング。SwiftUIの`.smooth(duration:)`と同じく、バウンスなしで`duration`を体感の長さにする。
    /// 止まるまでは`duration`より長くかかるので、動きの長さ（`duration`）は止まるまでの時間にする。
    static func rowSpring(keyPath: String, duration: TimeInterval) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: duration, bounce: 0)
        spring.keyPath = keyPath
        spring.duration = spring.settlingDuration
        return spring
    }
}
