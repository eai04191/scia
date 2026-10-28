import UIKit

/// 触れた瞬間を知らせるだけで、何も認識しないジェスチャー。ほかのジェスチャーとビューの操作を止めない。
final class TouchDownObserver: UIGestureRecognizer {
    private let onTouchDown: @MainActor (UITouch) -> Void

    init(onTouchDown: @escaping @MainActor (UITouch) -> Void) {
        self.onTouchDown = onTouchDown
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            onTouchDown(touch)
        }
        state = .failed
    }
}
