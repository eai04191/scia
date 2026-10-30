public import CoreGraphics
public import Foundation
import ImageIO

/// コマに分けた動く画像。アニメーションするカスタム絵文字（GIF、APNG）を描くのに使う。
/// コマは1枚の画像（`sheet`）に、左上から行ごとに格子状に並べて持つ。描く側は、画像を1度渡すだけで、表示する範囲を切り替えてコマを送れる。
/// コマごとに別の画像を持って差し替えるより、実機（iPhone 16 Pro）でスクロール中のhitchが半分ほどに減り、アプリのメモリも減った。
/// 描画のプロセスのCPUは変わらず、動く絵文字1個あたり約0.4%（iPhone SE 3で測った値）かかる。
public struct AnimatedImage: Sendable {
    /// 全コマを並べた画像。
    public let sheet: CGImage
    /// 1行に並べたコマの数。
    public let columns: Int
    /// 1コマの大きさ（ピクセル）。
    public let frameWidth: Int
    public let frameHeight: Int
    /// コマごとの、出しておく秒数。並びはコマの順。
    public let durations: [TimeInterval]

    public var frameCount: Int {
        durations.count
    }

    /// 1周の秒数。
    public var duration: TimeInterval {
        durations.reduce(0, +)
    }

    /// 並べた画像が使うメモリのバイト数。
    public var byteCount: Int {
        sheet.bytesPerRow * sheet.height
    }

    /// `index`番目のコマを切り出した画像。メニューのアイコンのように、画像を1枚ずつ渡す場所で使う。
    public func frameImage(at index: Int) -> CGImage? {
        let x = (index % columns) * (frameWidth + Self.gutter)
        let y = (index / columns) * (frameHeight + Self.gutter)
        return sheet.cropping(to: CGRect(x: x, y: y, width: frameWidth, height: frameHeight))
    }

    /// コマとコマのあいだに空ける、透明なすき間のピクセル数。
    /// 縮めて描くときは、表示する範囲のすぐ外の画素まで混ぜるため、隣のコマに接していると、その端が線や欠片になって見えた。
    public static let gutter = 2

    /// `index`番目のコマが、`sheet`のどこにあるか。左上を原点にした、幅と高さを1とする座標で返す。`CALayer.contentsRect`にそのまま渡せる。
    public func contentsRect(ofFrame index: Int) -> CGRect {
        let sheetWidth = Double(sheet.width)
        let sheetHeight = Double(sheet.height)
        return CGRect(
            x: Double((index % columns) * (frameWidth + Self.gutter)) / sheetWidth,
            y: Double((index / columns) * (frameHeight + Self.gutter)) / sheetHeight,
            width: Double(frameWidth) / sheetWidth,
            height: Double(frameHeight) / sheetHeight
        )
    }

    /// 展開したコマが使ってよいメモリの上限。超える画像は動かさず、静止画で描く。
    /// 絵文字を96pxで展開すると1コマ約36KBで、200コマ余りまで入る。それを超える長いアニメーションの絵文字はまれなため。
    public static let maxByteCount = 8 * 1024 * 1024

    /// 縮める前に原寸で展開してよい、1コマのピクセル数。1024×1024（4MB）。
    /// コマは前のコマと重ねるために原寸で展開してから縮めるため、他のサーバーの絵文字が小さなデータで巨大な大きさを宣言していると、
    /// 1コマで数百MBを使ってしまう。絵文字の元の画像はふつう数百px四方なので、超えるものは動かさない。
    public static let maxSourcePixelCount = 1024 * 1024

    /// 分けてよいコマの数。展開する前に、コマの数だけで断る。
    public static let maxFrameCount = 1000

    /// `data`を、長い辺が`maxPixelSize`ピクセル以下のコマに分けて並べる。2コマ以上ない画像、読めないデータ、
    /// 原寸が`maxSourcePixelCount`を超えるか`maxFrameCount`より多いコマの画像、展開すると`maxByteCount`を超える画像はnil。
    /// コマはImageIOが前のコマと重ねた、そのまま描ける画像になる。
    public static func decode(_ data: Data, maxPixelSize: Int) -> AnimatedImage? {
        guard !hasSeparateDefaultImage(data), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= maxFrameCount else { return nil }
        var frames: [(image: CGImage, duration: TimeInterval)] = []
        var byteCount = 0
        // 描くたびに展開し直さないよう、読むときに展開しておく。
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            guard let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width * height <= maxSourcePixelCount
            else { return nil }
            guard let image = CGImageSourceCreateImageAtIndex(source, index, options).flatMap({ scaled($0, maxPixelSize: maxPixelSize) }) else { return nil }
            // 並べた画像はRGBAで持つので、元のコマがグレースケールでも、RGBAに直した大きさで数える。
            byteCount += image.width * image.height * 4
            guard byteCount <= maxByteCount else { return nil }
            frames.append((image, frameDuration(properties)))
        }
        return sheet(of: frames)
    }

    /// コマを、なるべく正方形に近い格子に、すき間を空けて並べた画像にする。コマの大きさは最初のコマに揃える。
    /// GIFとAPNGのコマは、ImageIOが前のコマと重ねてキャンバス全体の大きさで返すので、ふつうは揃っている。
    private static func sheet(of frames: [(image: CGImage, duration: TimeInterval)]) -> AnimatedImage? {
        guard let first = frames.first?.image else { return nil }
        let columns = Int(Double(frames.count).squareRoot().rounded(.up))
        let rows = (frames.count + columns - 1) / columns
        let width = first.width
        let height = first.height
        let cellWidth = width + gutter
        let cellHeight = height + gutter
        let sheetWidth = cellWidth * columns - gutter
        let sheetHeight = cellHeight * rows - gutter
        // すき間と、最後の行の空いたコマの分だけ、コマの合計より大きくなるので、並べた画像でも上限を確かめる。
        guard sheetWidth * sheetHeight * 4 <= maxByteCount, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        for (index, frame) in frames.enumerated() {
            // CGContextは左下が原点なので、上の行から並べるよう、上端からの位置を下からの位置に直す。
            let top = (index / columns) * cellHeight
            let origin = CGPoint(x: (index % columns) * cellWidth, y: sheetHeight - top - height)
            context.draw(frame.image, in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        }
        guard let sheet = context.makeImage() else { return nil }
        return AnimatedImage(sheet: sheet, columns: columns, frameWidth: width, frameHeight: height, durations: frames.map(\.duration))
    }

    /// 既定の画像がアニメーションのコマに含まれないAPNG（最初の`fcTL`が`IDAT`より後にある）か。
    /// この形式では、macOS 27のImageIOがアニメーションの最初のコマを欠いて読むことを、テストで確かめた。iOSで同じかは確かめていない。
    /// 読み違えたコマで動かすより静止画のほうがよいので、この形式は動かさない。
    static func hasSeparateDefaultImage(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data)
        guard bytes.count > signature.count, Array(bytes[0..<signature.count]) == signature else { return false }
        var offset = signature.count
        var sawImageData = false
        // チャンクは、長さ（4バイト）、種類（4バイト）、中身、CRC（4バイト）の順に並ぶ。
        while offset + 8 <= bytes.count {
            let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            switch type {
            case "IDAT": sawImageData = true
            case "fcTL": return sawImageData
            case "IEND": return false
            default: break
            }
            offset += 12 + length
        }
        return false
    }

    /// コマを出しておく秒数。0.02秒より短いコマは、ブラウザと同じく0.1秒にする。カスタム絵文字とアイコンで同じ値を使う。
    /// GIFには0秒や0.01秒のコマを書く画像が多く、ブラウザはそれを0.1秒で描くため、そのまま使うと絵文字が速く回りすぎる。
    public static func frameDuration(_ properties: [CFString: Any]) -> TimeInterval {
        let keys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionaryKey, unclampedKey, clampedKey) in keys {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let delay = (dictionary[unclampedKey] as? Double) ?? (dictionary[clampedKey] as? Double) ?? 0
            return delay < 0.02 ? 0.1 : delay
        }
        return 0.1
    }

    /// 長い辺が`maxPixelSize`を超える画像を縮める。収まっていればそのまま返す。
    /// コマを前のコマと重ねた画像にするため、サムネイルの関数ではなく、重ねたコマを読んでから縮める。
    private static func scaled(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixelSize, longest > 0 else { return image }
        let scale = Double(maxPixelSize) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
