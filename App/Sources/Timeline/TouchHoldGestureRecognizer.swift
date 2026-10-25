import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 触れた時点で認識し、指がすべて離れるまで認識したままでいる。
///
/// 認識している間は、`cancelsTouchesInView`で触れたタッチを中身に渡さず、ほかのジェスチャーの認識も止める。
/// 認識してすぐ終えたり無効にしたりすると、タッチは中身に渡り、指を離したときに下のボタンやタップが効いてしまう。
/// 触れたときと離れたときは、target-actionではなく、タッチを受けたその場で知らせる。target-actionは後で配られることがあり、
/// 触れてから知らせるまでの間に、触れて止めたいものが動いてしまうため。
final class TouchHoldGestureRecognizer: UIGestureRecognizer {
    /// 触れて認識したとき。
    var onHold: (() -> Void)?
    /// 指がすべて離れたか、取り消されたとき。
    var onRelease: (() -> Void)?

    /// 触れてから離れるまでの間。
    var isHolding: Bool {
        state == .began || state == .changed
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible else { return }
        state = .began
        onHold?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if isHolding {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        // 離れたのが最後の指のときだけ終える。
        guard touches.count >= numberOfTouches else { return }
        finish(as: .ended)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(as: .cancelled)
    }

    private func finish(as finalState: UIGestureRecognizer.State) {
        guard isHolding else {
            state = .failed
            return
        }
        state = finalState
        onRelease?()
    }
}
