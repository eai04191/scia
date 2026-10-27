import SwiftUI
import UIKit

extension UIView {
    /// SwiftUIの`.smooth`のスプリングで動かす。UIKitの動きをSwiftUIの部品と揃えるため、時間で決める動きはこれで書く。
    /// `duration`が0以下なら動かさずにすぐ変え、完了もすぐ呼ぶ。チューニングで時間を0にすると、0秒のスプリングになるため。
    static func animateSmoothly(duration: TimeInterval, delay: TimeInterval = 0, changes: () -> Void, completion: (() -> Void)? = nil) {
        guard duration > 0 else {
            changes()
            completion?()
            return
        }
        let animation: Animation = delay > 0 ? .smooth(duration: duration).delay(delay) : .smooth(duration: duration)
        UIView.animate(animation, changes: changes, completion: completion)
    }

    /// 動かさずにすぐ変える。SwiftUIのスプリングで動かしている途中の値も、前と違う値にするなら、そこへ向け直して止める。
    /// `performWithoutAnimation`では、SwiftUIのスプリングの動きは止まらず、前の行き先へ動き続ける（アプリのテストで確かめた）。
    /// 前と同じ値を入れ直しても止まらないため、同じ値で止めたいときは`stopFading(at:)`のように一度別の値を入れる。
    static func performStoppingSmoothAnimations(_ changes: () -> Void) {
        UIView.animate(.linear(duration: 0), changes: changes)
    }

    /// SwiftUIのスプリングで動かしている濃さを止め、すぐ`alpha`にする。
    /// この動きはレイヤーのアニメーションを持たないため、`layer.removeAllAnimations()`でも、動きの外で値を入れても止まらない
    /// （アプリのテストで確かめた）。0秒の動きの中で一度別の値を入れてから`alpha`にすると、向け直されて止まる。
    func stopFading(at alpha: CGFloat) {
        UIView.animate(.linear(duration: 0)) {
            self.alpha = alpha == 0 ? 1 : 0
            self.alpha = alpha
        }
    }
}
