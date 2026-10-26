import CoreGraphics
import Foundation
import ImageIO
import Testing
import SciaTesting
import UniformTypeIdentifiers
@testable import SciaCore

@Suite(.scratch)
struct ImageCropTests {
    private let size = PixelSize(width: 200, height: 100)

    /// 回さなければ、割合をそのまま画素にする。
    @Test func mapsRectWithoutRotation() {
        let crop = ImageCrop(quarterTurns: 0, rect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        #expect(crop.sourceRect(in: size) == CGRect(x: 50, y: 50, width: 100, height: 50))
        #expect(crop.outputSize(of: size) == PixelSize(width: 100, height: 50))
    }

    /// 時計回りに1回回すと、回したあとの左上は元の左下になる。回したあとの上半分は、元の左半分。
    @Test func mapsRectAfterQuarterTurn() {
        let crop = ImageCrop(quarterTurns: 1, rect: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        #expect(crop.rotatedSize(of: size) == PixelSize(width: 100, height: 200))
        #expect(crop.sourceRect(in: size) == CGRect(x: 0, y: 0, width: 100, height: 100))
        // 回したあとの左上の4分の1は、元の左下の4分の1。
        let corner = ImageCrop(quarterTurns: 1, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(corner.sourceRect(in: size) == CGRect(x: 0, y: 50, width: 100, height: 50))
        #expect(corner.outputSize(of: size) == PixelSize(width: 50, height: 100))
    }

    /// 2回回すと、回したあとの左上は元の右下になる。
    @Test func mapsRectAfterHalfTurn() {
        let crop = ImageCrop(quarterTurns: 2, rect: CGRect(x: 0, y: 0, width: 0.25, height: 0.5))
        #expect(crop.sourceRect(in: size) == CGRect(x: 150, y: 50, width: 50, height: 50))
    }

    /// 3回（反時計回りに1回）回すと、回したあとの左上は元の右上になる。
    @Test func mapsRectAfterThreeQuarterTurns() {
        let crop = ImageCrop(quarterTurns: 3, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(crop.sourceRect(in: size) == CGRect(x: 100, y: 0, width: 100, height: 50))
        #expect(crop.outputSize(of: size) == PixelSize(width: 50, height: 100))
    }

    /// 回す回数は0から3に、範囲は画像の中に収める。画像の外しか指していなければ全体を残す。
    @Test func normalizesTurnsAndClampsRect() {
        #expect(ImageCrop(quarterTurns: -1, rect: ImageCrop.unitRect).quarterTurns == 3)
        #expect(ImageCrop(quarterTurns: 5, rect: ImageCrop.unitRect).quarterTurns == 1)
        #expect(ImageCrop(quarterTurns: 0, rect: CGRect(x: -0.5, y: 0.5, width: 1, height: 1)).rect == CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        #expect(ImageCrop(quarterTurns: 0, rect: CGRect(x: 2, y: 2, width: 1, height: 1)).rect == ImageCrop.unitRect)
    }

    /// 画素に揃えて全体なら、切り抜かないのと同じ。回したら違う。
    @Test func identityIsJudgedInPixels() {
        #expect(ImageCrop(quarterTurns: 0, rect: CGRect(x: 0.001, y: 0, width: 0.998, height: 1)).isIdentity(in: size))
        #expect(!ImageCrop(quarterTurns: 0, rect: CGRect(x: 0.01, y: 0, width: 0.99, height: 1)).isIdentity(in: size))
        #expect(!ImageCrop(quarterTurns: 2, rect: ImageCrop.unitRect).isIdentity(in: size))
    }

    /// 割合が丸めの誤差でずれても、同じ画素なら同じ範囲とする。nilは全体を残すのと同じ。
    @Test func comparesCropsInPixels() {
        let half = ImageCrop(quarterTurns: 0, rect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let nearlyHalf = ImageCrop(quarterTurns: 0, rect: CGRect(x: 0.000_001, y: 0, width: 0.499_998, height: 0.999_999))
        #expect(ImageCrop.selectsSamePixels(half, nearlyHalf, in: size))
        #expect(!ImageCrop.selectsSamePixels(half, ImageCrop(quarterTurns: 1, rect: half.rect), in: size))
        #expect(ImageCrop.selectsSamePixels(nil, ImageCrop(quarterTurns: 0, rect: ImageCrop.unitRect), in: size))
        #expect(!ImageCrop.selectsSamePixels(nil, half, in: size))
    }

    /// とても細い範囲でも、1画素は残す。
    @Test func keepsAtLeastOnePixel() {
        let crop = ImageCrop(quarterTurns: 0, rect: CGRect(x: 0.5, y: 0.5, width: 0.0001, height: 0.0001))
        #expect(crop.outputSize(of: size) == PixelSize(width: 1, height: 1))
    }
}

@Suite(.scratch)
struct CropBoxTests {
    private let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)

    /// 縦横比を決めると、範囲に収まる一番大きい枠を中央に置く。
    @Test func fitsAspectRatioInBounds() {
        #expect(CropBox.fit(aspectRatio: 1, in: bounds) == CGRect(x: 50, y: 0, width: 200, height: 200))
        #expect(CropBox.fit(aspectRatio: 3, in: bounds) == CGRect(x: 0, y: 50, width: 300, height: 100))
    }

    /// 比率を決めなければ、動かした辺だけが動き、範囲の外と最小の長さの手前で止まる。
    @Test func freeResizeClampsToBoundsAndMinimum() {
        let box = CGRect(x: 100, y: 50, width: 100, height: 100)
        #expect(CropBox.resize(box, handle: .topLeft, by: CGVector(dx: -500, dy: 20), within: bounds, minimumSide: 40, aspectRatio: nil)
            == CGRect(x: 0, y: 70, width: 200, height: 80))
        #expect(CropBox.resize(box, handle: .right, by: CGVector(dx: -90, dy: 30), within: bounds, minimumSide: 40, aspectRatio: nil)
            == CGRect(x: 100, y: 50, width: 40, height: 100))
    }

    /// 比率を決めた角のハンドルは、対角の角を固定して比率を保ち、範囲の外に出さない。
    @Test func cornerResizeKeepsRatioAndAnchor() {
        let box = CGRect(x: 100, y: 50, width: 100, height: 50)
        let grown = CropBox.resize(box, handle: .bottomRight, by: CGVector(dx: 40, dy: 20), within: bounds, minimumSide: 40, aspectRatio: 2)
        #expect(grown == CGRect(x: 100, y: 50, width: 140, height: 70))
        // 右には200しか余裕がないので、幅200（高さ100）で止まる。
        let limited = CropBox.resize(box, handle: .bottomRight, by: CGVector(dx: 1000, dy: 1000), within: bounds, minimumSide: 40, aspectRatio: 2)
        #expect(limited == CGRect(x: 100, y: 50, width: 200, height: 100))
        // 縮めても、短い辺が最小の長さを下回らない。
        let shrunk = CropBox.resize(box, handle: .topLeft, by: CGVector(dx: 1000, dy: 1000), within: bounds, minimumSide: 40, aspectRatio: 2)
        #expect(shrunk == CGRect(x: 120, y: 60, width: 80, height: 40))
    }

    /// 比率を決めた辺のハンドルは、向かいの辺の中央を固定して、もう一方の向きに両側へ広げる。
    @Test func edgeResizeKeepsCenterOfOppositeEdge() {
        let box = CGRect(x: 100, y: 75, width: 100, height: 50)
        let grown = CropBox.resize(box, handle: .right, by: CGVector(dx: 60, dy: 0), within: bounds, minimumSide: 40, aspectRatio: 2)
        #expect(grown == CGRect(x: 100, y: 60, width: 160, height: 80))
        // 上下の余裕は中央から100ずつなので、高さ200（幅400）まで。右の余裕200のほうが先に効く。
        let limited = CropBox.resize(box, handle: .right, by: CGVector(dx: 1000, dy: 0), within: bounds, minimumSide: 40, aspectRatio: 2)
        #expect(limited == CGRect(x: 100, y: 50, width: 200, height: 100))
    }
}

@Suite(.scratch)
struct CropRotationPoseTests {
    private let center = CGPoint(x: 200, y: 400)

    private func apply(_ pose: CropRotationPose, to point: CGPoint) -> CGPoint {
        // UIView.transformと同じく、中心からの位置に変形を当てて中心に戻す。
        let relative = CGPoint(x: point.x - center.x, y: point.y - center.y).applying(pose.affineTransform)
        return CGPoint(x: relative.x + center.x, y: relative.y + center.y)
    }

    private func isClose(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.001 && abs(lhs.y - rhs.y) < 0.001
    }

    /// 回したあとの枠の角を、回す前の枠の角に重ねる。反時計回りに回すと、前の右上が左上に、前の左上が左下に来るので、それぞれ元の角に戻す。
    @Test func undoingTurnMapsRotatedBoxOntoOriginal() {
        let original = CGRect(x: 20, y: 300, width: 360, height: 200)
        let rotated = CGRect(x: 100, y: 200, width: 200, height: 360)
        let pose = CropRotationPose.undoingCounterclockwiseTurn(from: rotated, to: original, around: center)
        #expect(isClose(apply(pose, to: CGPoint(x: rotated.minX, y: rotated.minY)), CGPoint(x: original.maxX, y: original.minY)))
        #expect(isClose(apply(pose, to: CGPoint(x: rotated.minX, y: rotated.maxY)), CGPoint(x: original.minX, y: original.minY)))
        #expect(isClose(apply(pose, to: CGPoint(x: rotated.midX, y: rotated.midY)), CGPoint(x: original.midX, y: original.midY)))
    }

    /// 重ねた変形は、内側を当ててから外側を当てたのと同じ点に移す。角度は足したまま持ち、180°を超えても回る向きを保つ。
    @Test func composesWithoutWrappingTheAngle() {
        let inner = CropRotationPose(angle: .pi / 2, scale: 0.5, translation: CGVector(dx: 10, dy: -20))
        let outer = CropRotationPose(angle: .pi * 0.8, scale: 2, translation: CGVector(dx: -5, dy: 7))
        let composed = inner.followed(by: outer)
        let point = CGPoint(x: 50, y: 120)
        #expect(isClose(apply(composed, to: point), apply(outer, to: apply(inner, to: point))))
        #expect(abs(composed.angle - .pi * 1.3) < 0.000_1)
        // 補間の途中も、角度は大きいほうから0へまっすぐ減る。行列の補間のように近い向きへ逆回りしない。
        #expect(abs(composed.approachingIdentity(fraction: 0.5, pivot: center, around: center).angle - .pi * 0.65) < 0.000_1)
    }

    /// 回す軸にした点は、補間の途中も、始めの見えている位置から終わりの位置へまっすぐ動く。
    /// 画面の中央から外れた枠を、その場で回すときは、枠の中心が動かない。
    @Test func pivotStaysOnStraightPath() {
        let original = CGRect(x: 20, y: 330, width: 362, height: 242)
        let rotated = CGRect(x: 20, y: 180.5, width: 362, height: 541)
        let pose = CropRotationPose.undoingCounterclockwiseTurn(from: rotated, to: original, around: center)
        let pivot = CGPoint(x: rotated.midX, y: rotated.midY)
        #expect(isClose(apply(pose.approachingIdentity(fraction: 0, pivot: pivot, around: center), to: pivot), CGPoint(x: original.midX, y: original.midY)))
        for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
            let shown = apply(pose.approachingIdentity(fraction: fraction, pivot: pivot, around: center), to: pivot)
            #expect(isClose(shown, pivot))
        }
        #expect(pose.approachingIdentity(fraction: 1, pivot: pivot, around: center).affineTransform.isIdentity)
    }
}

@Suite(.scratch)
struct ImageCropEncodingTests {
    /// 左上を赤、右上を緑、左下を青、右下を白に塗った画像をPNGで書き出す。
    private func writeQuadrants(width: Int, height: Int, to url: URL) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let halfWidth = CGFloat(width) / 2, halfHeight = CGFloat(height) / 2
        // Core Graphicsは下が原点なので、上半分はyの大きい側。
        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight), CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
        ]
        for (rect, color) in quadrants {
            context.setFillColor(color)
            context.fill(rect)
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// 書き出した画像の、四隅から5画素内側の色。左上、右上、左下、右下の順に、赤、緑、青を0か255で返す。
    /// 読み込むときに色空間を変換して値が少しずれる（緑が249になるなど）ため、半分を境に0か255に丸めて、どの色かだけを比べる。
    private func corners(of url: URL) throws -> [[UInt8]] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        // 描き先のメモリは、上の行から並ぶ。
        return [(5, 5), (width - 6, 5), (5, height - 6), (width - 6, height - 6)].map { x, y in
            let offset = (y * width + x) * 4
            return pixels[offset..<offset + 3].map { $0 >= 128 ? 255 : 0 }
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = TestScratch.url("ImageCropEncodingTests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 切り抜くときは、収まっていても作り直す計画にし、元の容量で上限を超えたことにはしない。
    @Test func planReencodesWhenCropping() {
        let limits = MediaLimits(imageSizeLimit: 1000, imageMatrixLimit: nil, videoSizeLimit: nil, videoMatrixLimit: nil, videoFrameRateLimit: nil)
        let plan = ImagePlan.make(
            size: PixelSize(width: 100, height: 100), byteCount: 5000, mimeType: "image/png", setting: .original, limits: limits,
            supportedMIMETypes: nil, unprocessableMIMETypes: [], cropping: true
        )
        #expect(plan == ImagePlan(mimeType: "image/png", size: PixelSize(width: 100, height: 100), sizeBySetting: PixelSize(width: 100, height: 100), exceedsSizeLimit: false))
    }

    /// 時計回りに1回回すと、元の左上（赤）が右上に、左下（青）が左上に、右上（緑）が右下に来る。
    @Test func rotatesClockwise() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "source.png")
        try writeQuadrants(width: 200, height: 100, to: source)
        let crop = ImageCrop(quarterTurns: 1, rect: ImageCrop.unitRect)
        let size = crop.outputSize(of: PixelSize(width: 200, height: 100))
        let plan = ImagePlan(mimeType: "image/png", size: size, sizeBySetting: size, exceedsSizeLimit: false)
        let prepared = try await ImageReencoder.reencode(source, plan: plan, crop: crop, originalSize: size, sizeLimit: nil, quality: 0.9, destination: directory.appending(path: "out"))

        #expect(prepared.size == PixelSize(width: 100, height: 200))
        let colors = try corners(of: prepared.url)
        #expect(colors == [[0, 0, 255], [255, 0, 0], [255, 255, 255], [0, 255, 0]])
    }

    /// 切り抜いてから計画の大きさに縮める。右半分を切り抜くと、緑と白だけが残る。
    @Test func cropsThenScales() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "source.png")
        try writeQuadrants(width: 200, height: 100, to: source)
        let crop = ImageCrop(quarterTurns: 0, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let plan = ImagePlan(mimeType: "image/png", size: PixelSize(width: 50, height: 50), sizeBySetting: PixelSize(width: 50, height: 50), exceedsSizeLimit: false)
        let prepared = try await ImageReencoder.reencode(source, plan: plan, crop: crop, originalSize: PixelSize(width: 100, height: 100), sizeLimit: nil, quality: 0.9, destination: directory.appending(path: "out"))

        #expect(prepared.size == PixelSize(width: 50, height: 50))
        let colors = try corners(of: prepared.url)
        #expect(colors == [[0, 255, 0], [0, 255, 0], [255, 255, 255], [255, 255, 255]])
    }

    /// 2回と3回回したときも、見た目どおりの向きになる。
    @Test func rotatesHalfAndThreeQuarterTurns() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "source.png")
        try writeQuadrants(width: 200, height: 100, to: source)
        for (turns, topLeft) in [(2, [255, 255, 255] as [UInt8]), (3, [0, 255, 0])] {
            let crop = ImageCrop(quarterTurns: turns, rect: ImageCrop.unitRect)
            let size = crop.outputSize(of: PixelSize(width: 200, height: 100))
            let plan = ImagePlan(mimeType: "image/png", size: size, sizeBySetting: size, exceedsSizeLimit: false)
            let prepared = try await ImageReencoder.reencode(source, plan: plan, crop: crop, originalSize: size, sizeLimit: nil, quality: 0.9, destination: directory.appending(path: "out-\(turns)"))
            let colors = try corners(of: prepared.url)
            #expect(colors.first == topLeft)
        }
    }
}
