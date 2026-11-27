import ImageIO
import SciaCore
import Testing
import UIKit
@testable import Scia

@MainActor
@Suite(.failureState)
struct PreviewImagesTests {
    /// 見本の画像は通信の層を通さずに読む。通信の層はhttpとhttps以外を送らず、Releaseには`file:`を読む障害の差し込みもないため、
    /// ファイルのURLを渡すと、Releaseでだけ灰色の四角のまま出なかった。
    @Test(arguments: ["avatar", "card-light", "card-dark"])
    func loadsWithoutNetwork(name: String) async throws {
        let url = try #require(Self.url(named: name))
        #expect(!url.isFileURL)
        #expect(url.scheme != "http" && url.scheme != "https")
        let data = try await AppDependencies.imageData(from: url)
        #expect(UIImage(data: data) != nil)
    }

    /// 見本のアイコンと絵文字の絵は、四隅まで不透明。アイコンの形と角の丸さで切り抜くときも、切り抜かれない絵文字でも、元のアイコンの角丸の透明な部分が見えないようにするため。
    @Test func avatarCornersAreOpaque() async throws {
        let url = try #require(PreviewImages.avatarURL())
        let data = try await AppDependencies.imageData(from: url)
        let image = try #require(UIImage(data: data)?.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context != nil
        }
        try #require(drawn)
        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
            #expect(pixels[(y * width + x) * 4 + 3] == 255, "(\(x), \(y))が透けています")
        }
    }

    /// 見本の動くアイコンのコマの長さは、どれも1/100秒で割り切れる。アイコンの再生（`AvatarImageStore`）は1/100秒に丸め、絵文字の再生は丸めないため、割り切れないとアイコンだけ速く動く。
    @Test func animatedAvatarFrameDurationsAreWholeCentiseconds() async throws {
        let url = try #require(await PreviewImages.animatedAvatarWhenReady())
        let data = try await AppDependencies.imageData(from: url)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let count = CGImageSourceGetCount(source)
        #expect(count > 1)
        for index in 0..<count {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let centiseconds = AnimatedImage.frameDuration(properties) * 100
            #expect(abs(centiseconds - centiseconds.rounded()) < 0.001, "\(index)コマ目が\(centiseconds)/100秒です")
        }
    }

    private static func url(named name: String) -> URL? {
        switch name {
        case "avatar": PreviewImages.avatarURL()
        case "card-light": PreviewImages.cardURL(for: .light)
        default: PreviewImages.cardURL(for: .dark)
        }
    }
}
