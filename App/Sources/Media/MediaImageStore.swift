import Foundation
import ImageIO
import os
import SciaCore
import UIKit

/// 添付ファイルの画像を読み込み、メモリに持つ。
///
/// 絵文字と違って1枚が大きく、スクロールし続けると際限なく増えるため、上限のあるキャッシュに入れる。
/// 描画のたびにメインスレッドで展開しないよう、表示する大きさまで縮めて展開したものを持つ。
@MainActor
final class MediaImageStore {
    typealias Fetch = @Sendable (URL) async throws -> Data

    /// ビューアで拡大して見る画像を展開する最大の辺の長さ（ピクセル）。これより大きい画像は縮めて持つ。
    static let fullPixelSize = 4_096

    private let fetch: Fetch
    /// 同じURLでも縮める大きさごとに分けて持つ。サーバーによってはプレビューと元の画像が同じURLのため。
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [Key: Task<UIImage, any Error>] = [:]
    private let logger = SciaLog.logger(category: "media")

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
        // 4096px四方の画像が4枚ほど入る大きさ。
        cache.totalCostLimit = 256 * 1_024 * 1_024
    }

    private struct Key: Hashable {
        let url: URL
        let maxPixelSize: Int

        var cacheKey: NSString { "\(maxPixelSize) \(url.absoluteString)" as NSString }
    }

    func cachedImage(for url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: Key(url: url, maxPixelSize: maxPixelSize).cacheKey)
    }

    /// 画像を読み込む。同じURLを読み込んでいる途中なら、その結果を待つ。
    /// 呼び出し側のタスクを取り消しても、読み込みは止めずにキャッシュへ入れる。同じ画像がすぐまた求められることが多いため。
    func image(for url: URL, maxPixelSize: Int) async throws -> UIImage {
        let key = Key(url: url, maxPixelSize: maxPixelSize)
        if let image = cache.object(forKey: key.cacheKey) {
            return image
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let fetch = fetch
        let task = Task<UIImage, any Error> {
            let data = try await fetch(url)
            guard let image = await Self.decode(data, maxPixelSize: maxPixelSize) else {
                throw DecodeError()
            }
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let image = try await task.value
            cache.setObject(image, forKey: key.cacheKey, cost: Self.cost(of: image))
            return image
        } catch {
            logger.error("media load failed url=\(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// blurhashを、`aspectRatio`（幅÷高さ）の小さな画像に展開する。表示するときに拡大してぼかしとして見せるため、
    /// 長い辺を32ピクセルにする。文字列が仕様どおりでなければnil。
    func placeholder(for blurhash: String, aspectRatio: Double?) -> UIImage? {
        let longSide = 32
        let ratio = aspectRatio ?? 1
        let width = ratio >= 1 ? longSide : max(Int((Double(longSide) * ratio).rounded()), 1)
        let height = ratio >= 1 ? max(Int((Double(longSide) / ratio).rounded()), 1) : longSide
        let key = "blurhash \(width)x\(height) \(blurhash)" as NSString
        if let image = cache.object(forKey: key) {
            return image
        }
        guard let image = BlurHash(blurhash).flatMap({ Self.makeImage(rgba: $0.rgba(width: width, height: height), width: width, height: height) }) else {
            logger.error("blurhash decode failed hash=\(blurhash, privacy: .public)")
            return nil
        }
        cache.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    private static func makeImage(rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: image)
    }

    struct DecodeError: Error {}

    /// `maxPixelSize`まで縮め、描画できる状態まで展開する。重い処理のため、メインスレッドの外で行う。
    @concurrent
    private static func decode(_ data: Data, maxPixelSize: Int) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
