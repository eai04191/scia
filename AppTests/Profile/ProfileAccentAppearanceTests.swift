import ImageIO
import SciaCore
import SciaTesting
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Scia

/// カードの色を付けても、ラベルの元の文字列（アニメーションする絵文字の静止画など）を壊さない。
@MainActor
struct ProfileAccentAppearanceTests {
    private let clock = TestClock()
    private let url = URL(filePath: "/").appending(path: "emoji.gif")
    private static let side = 20

    /// 同じ赤の2コマのGIF。2コマあるので、ストアはアニメーションする絵文字として読む。
    private static func gif() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let frame = try #require(UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        for _ in 0 ..< 2 { CGImageDestinationAddImage(destination, frame, nil) }
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// アニメーションする絵文字と、控えめな文字のリンクを描いているラベル。絵文字は、動かすために透明な場所取りに差し替わっている。
    private func animatingLabel() async throws -> (EmojiLabel, UIWindow) {
        let data = try Self.gif()
        let store = EmojiImageStore(clock: clock) { _ in data }
        _ = store.animation(for: url)
        try await waitUntil { store.animation(for: url) != nil }
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
        let label = EmojiLabel(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        window.addSubview(label)
        window.isHidden = false
        label.emojiImages = store
        let attachment = NSTextAttachment(image: try #require(UIImage(data: data)))
        attachment.bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttribute(.customEmoji, value: CustomEmoji(shortcode: "emoji", url: url, staticUrl: url), range: NSRange(location: 0, length: 1))
        text.append(NSAttributedString(string: "link", attributes: [.foregroundColor: UIColor.secondaryLabel, .linkDestination: "https://example.com"]))
        label.attributedText = text
        try await waitUntil {
            label.layoutIfNeeded()
            return Self.emojiWidth(in: label) != CGFloat(Self.side)
        }
        return (label, window)
    }

    private static func emojiWidth(in label: UILabel) -> CGFloat? {
        (label.attributedText?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image?.size.width
    }

    @Test("控えめな文字を塗り替えても、アニメーションをやめたときに絵文字の静止画に戻る")
    func recolorKeepsStillEmoji() async throws {
        let (label, window) = try await animatingLabel()
        ProfileAccentAppearance.recolorSecondaryText(in: label, to: .white)
        label.emojiImages = nil
        #expect(Self.emojiWidth(in: label) == CGFloat(Self.side))
        #expect(label.attributedText?.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? UIColor == .white)
        window.isHidden = true
    }

    @Test("リンクに下線を引いても、アニメーションをやめたときに絵文字の静止画に戻る")
    func restyleKeepsStillEmoji() async throws {
        let (label, window) = try await animatingLabel()
        ProfileAccentAppearance.restyleLinks(in: label, underline: true, badge: nil)
        label.emojiImages = nil
        #expect(Self.emojiWidth(in: label) == CGFloat(Self.side))
        #expect(label.attributedText?.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        window.isHidden = true
    }
}
