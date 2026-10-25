import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
struct ProfileImageCropAccessibilityTests {
    private func cropElement(in view: UIView) -> CropAccessibilityElement? {
        if let element = view.accessibilityElements?.compactMap({ $0 as? CropAccessibilityElement }).first {
            return element
        }
        return view.subviews.lazy.compactMap(cropElement(in:)).first
    }

    /// ピンチとドラッグの代わりに、VoiceOverでは上下のスワイプで拡大縮小し、操作で範囲を動かす。
    @Test func voiceOverZoomsAndMovesTheCrop() throws {
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }()).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }.cgImage)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = ProfileImageCropViewController(image: image, kind: .avatar, avatarShape: .circle)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let element = try #require(cropElement(in: controller.view))

        #expect(element.accessibilityTraits.contains(.adjustable))
        #expect(element.accessibilityValue == "拡大100%、横50%、縦50%")

        element.accessibilityIncrement()
        #expect(element.accessibilityValue == "拡大125%、横50%、縦50%")

        let right = try #require(element.accessibilityCustomActions?.first { $0.name == "範囲を右へ" })
        #expect(right.actionHandler?(right) == true)
        let value = try #require(element.accessibilityValue)
        #expect(value.hasPrefix("拡大125%、横") && !value.hasPrefix("拡大125%、横50%"))

        element.accessibilityDecrement()
        element.accessibilityDecrement()
        #expect(element.accessibilityValue?.hasPrefix("拡大100%") == true)
    }
}
