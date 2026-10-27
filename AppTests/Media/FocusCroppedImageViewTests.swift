import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct FocusCroppedImageViewTests {
    /// 触れたものを奥へ通す。ビューアの複製は開く途中もページより手前にあり、受けると左右のスワイプがページに届かない。
    @Test func passesTouchesThrough() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = FocusCroppedImageView(frame: container.bounds)
        view.image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { _ in }
        container.addSubview(view)

        #expect(container.hitTest(CGPoint(x: 50, y: 50), with: nil) === container)
    }

    /// 焦点に合わせて中の画像をずらし、枠の外は切り抜く。
    @Test func shiftsImageToFocus() throws {
        let view = FocusCroppedImageView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { _ in }
        view.focus = MediaFocus(x: -0.25, y: 0)
        view.layoutIfNeeded()

        let imageView = try #require(view.subviews.first { $0 is UIImageView })
        #expect(view.clipsToBounds)
        #expect(imageView.frame == CGRect(x: -25, y: 0, width: 200, height: 100))
    }
}
