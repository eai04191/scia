import CoreGraphics
import Testing
@testable import SciaCore

struct BannerLuminanceTests {
    /// 上半分と下半分を塗り分けた画像。
    private func image(top: CGColor, bottom: CGColor, width: Int = 30, height: Int = 10) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // CGContextの座標は下から上へ伸びるため、上半分はyの大きいほう。
        context.setFillColor(bottom)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(top)
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return try #require(context.makeImage())
    }

    private let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    @Test func measuresRowsFromTheTop() throws {
        let luminance = try #require(BannerLuminance(image: try image(top: black, bottom: white), rowCount: 4, columnCount: 2))
        #expect(luminance.rows.count == 4)
        #expect(luminance.rows[0] < 0.01)
        #expect(luminance.rows[3] > 0.99)
    }

    @Test func treatsTransparentPixelsAsWhite() throws {
        let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        let luminance = try #require(BannerLuminance(image: try image(top: clear, bottom: clear), rowCount: 2, columnCount: 2))
        #expect(luminance.rows.allSatisfy { $0 > 0.99 })
    }

    @Test func bandAboveTheBannerReadsTheMirroredRows() {
        // 上の半分が暗く、下の半分が明るい画像。上端の行は暗い。
        let luminance = BannerLuminance(rows: [0, 0, 1, 1])
        // 上端のすぐ上は、折り返して上端の暗い行を見る。
        #expect(luminance.luminance(underBandFrom: -40, to: -10, bannerHeight: 100) == 0)
        // 上端から画像の高さの半分より上は、折り返して下半分の明るい行を見る。
        #expect(luminance.luminance(underBandFrom: -90, to: -60, bannerHeight: 100) == 1)
        // 画像の高さより遠い部分は、下端の行を見る。
        #expect(luminance.luminance(underBandFrom: -300, to: -200, bannerHeight: 100) == 1)
        // 画像の上に重なる帯は、そのまま重なる行を見る。
        #expect(luminance.luminance(underBandFrom: 10, to: 40, bannerHeight: 100) == 0)
    }

    @Test func bandWithoutSizeHasNoLuminance() {
        let luminance = BannerLuminance(rows: [0.5])
        #expect(luminance.luminance(underBandFrom: 0, to: 0, bannerHeight: 100) == nil)
        #expect(luminance.luminance(underBandFrom: 0, to: 10, bannerHeight: 0) == nil)
        #expect(BannerLuminance(rows: []).luminance(underBandFrom: 0, to: 10, bannerHeight: 100) == nil)
    }

    @Test func choosesTheTextWithMoreContrast() {
        #expect(StatusBarTextTone(backgroundLuminance: 0) == .light)
        #expect(StatusBarTextTone(backgroundLuminance: 0.17) == .light)
        #expect(StatusBarTextTone(backgroundLuminance: 0.19) == .dark)
        #expect(StatusBarTextTone(backgroundLuminance: 1) == .dark)
    }

    @Test func relativeLuminanceFollowsWCAG() {
        #expect(BannerLuminance.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
        #expect(abs(BannerLuminance.relativeLuminance(red: 255, green: 255, blue: 255) - 1) < 1e-9)
        // sRGBの中間の灰色（128）の相対輝度は約0.216。
        #expect(abs(BannerLuminance.relativeLuminance(red: 128, green: 128, blue: 128) - 0.2158) < 0.001)
    }

    /// 白の地に、`blackRect`（CGContextの座標、左下が原点）を黒く塗った画像。
    private func image(width: Int, height: Int, blackRect: CGRect) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(black)
        context.fill(blackRect)
        return try #require(context.makeImage())
    }

    @Test func tallImageIsMeasuredWithinTheVisibleCrop() throws {
        // 上の200pxだけが白く、3:4の枠に見える真ん中の300pxはすべて黒い。
        let source = try image(width: 400, height: 800, blackRect: CGRect(x: 0, y: 0, width: 400, height: 600))
        let luminance = try #require(BannerLuminance(image: source, frameAspect: 0.75))
        #expect(luminance.rows.allSatisfy { $0 < 0.01 })
    }

    @Test func wideImageIsMeasuredWithoutTheCroppedSides() throws {
        // 左右の白い部分は3:1の枠の外にあり、見える真ん中の300pxは黒い。
        let source = try image(width: 1200, height: 100, blackRect: CGRect(x: 450, y: 0, width: 300, height: 100))
        let luminance = try #require(BannerLuminance(image: source, frameAspect: 1.0 / 3))
        #expect(luminance.rows.allSatisfy { $0 < 0.01 })
    }
}
