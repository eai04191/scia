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

    /// 薄くして入れ替えると、前の画像の像を中の画像いっぱいに重ねて残す。1コマで替えるときは、薄くしている途中の像も外す。
    @Test func crossfadeKeepsPreviousImageOverNewOne() throws {
        let view = FocusCroppedImageView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let placeholder = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { _ in }
        let original = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { _ in }
        view.image = placeholder
        view.layoutIfNeeded()
        let imageView = try #require(view.subviews.first { $0 is UIImageView } as? UIImageView)
        #expect(imageView.subviews.isEmpty)

        view.setImage(original, crossfadeDuration: 0.15)
        view.layoutIfNeeded()

        #expect(view.lastCrossfadeDuration == 0.15)
        let copy = try #require(imageView.subviews.first as? UIImageView)
        #expect(copy.image === placeholder)
        #expect(copy.frame == imageView.bounds)

        // 薄くしている途中に1コマで差し替えたら、前の画像の像を残さない。残すと、別の画像の手前に前の画像が重なって見える。
        view.image = placeholder
        #expect(view.lastCrossfadeDuration == 0)
        #expect(imageView.subviews.isEmpty)
    }
}
