public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 送るために作り直したメディアのファイル。
public struct PreparedMedia: Sendable, Equatable {
    public let url: URL
    public let mimeType: String
    public let size: PixelSize
    /// サーバーの上限のために、設定で選んだより小さく、または低い画質にしたときの変化。設定どおりならnil。
    public let reduction: MediaReduction?

    public init(url: URL, mimeType: String, size: PixelSize, reduction: MediaReduction?) {
        self.url = url
        self.mimeType = mimeType
        self.size = size
        self.reduction = reduction
    }
}

/// サーバーの上限のために縮めたときの、前と後。
public struct MediaReduction: Sendable, Equatable {
    public let fromSize: PixelSize
    public let toSize: PixelSize
    public let fromByteCount: Int
    public let toByteCount: Int

    public init(fromSize: PixelSize, toSize: PixelSize, fromByteCount: Int, toByteCount: Int) {
        self.fromSize = fromSize
        self.toSize = toSize
        self.fromByteCount = fromByteCount
        self.toByteCount = toByteCount
    }
}

/// 作り直せなかった。
public enum MediaReencodingError: Error, Equatable, LocalizedError {
    /// 画像を読めなかった、または書き出せなかった。
    case imageFailed
    /// 縮めても、サーバーの容量の上限に収まらなかった。
    case cannotFitSizeLimit
    /// 解像度を下げても見られる画質にならないほど長く、サーバーの上限に収められない。
    case videoTooLong
    /// 動画を読めなかった、または書き出せなかった。
    case videoFailed

    public var errorDescription: String? {
        switch self {
        case .imageFailed: "画像を作り直せませんでした。"
        case .cannotFitSizeLimit: "サーバーの上限に収まるよう縮められませんでした。"
        case .videoTooLong: "動画が長すぎて、サーバーの上限に収められません。"
        case .videoFailed: "動画を書き出せませんでした。"
        }
    }
}

public enum ImageReencoder {
    /// 向きを反映した大きさ。読めなければnil。
    public static func size(of url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // 5〜8は90度回した向きで、見えるときは幅と高さが入れ替わる。
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
    }

    /// 計画どおりの大きさと形式で作り直す。容量の上限を超えたら、収まるまで解像度を下げて作り直す。
    ///
    /// 向きは画素に反映し、位置情報などのメタデータは書き出さない。色空間（Display P3など）は画像の色空間として残る。
    /// - Parameters:
    ///   - originalSize: 元の大きさ。設定どおりに縮めたかを比べるのに使う。
    ///   - quality: JPEGとHEICの品質。PNGでは使わない。
    ///   - destination: 書き出す先のファイル。拡張子は形式に合わせて付け替える。
    @concurrent
    public static func reencode(
        _ url: URL,
        plan: ImagePlan,
        originalSize: PixelSize,
        sizeLimit: Int?,
        quality: Double,
        destination: URL
    ) async throws -> PreparedMedia {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = UTType(mimeType: plan.mimeType)
        else { throw MediaReencodingError.imageFailed }
        let output = destination.deletingPathExtension().appendingPathExtension(type.preferredFilenameExtension ?? "img")
        let originalByteCount = byteCount(of: url)
        var size = plan.size
        while true {
            try Task.checkCancellation()
            let written = try write(source, size: size, type: type, quality: plan.mimeType == "image/png" ? nil : quality, to: output)
            let byteCount = byteCount(of: output)
            if sizeLimit.map({ byteCount <= $0 }) ?? true {
                // 設定で選んだ大きさのとおりに縮めただけなら、使う人が選んだ変化なので知らせない。
                let matchesSetting = plan.sizeBySetting != originalSize && size == plan.sizeBySetting
                // 処理できない形式を、大きさを変えずに作り直しただけなら、縮めていないので知らせない。
                let convertsFormatOnly = size == originalSize && !plan.exceedsSizeLimit
                let reduction = matchesSetting || convertsFormatOnly ? nil : MediaReduction(fromSize: originalSize, toSize: written, fromByteCount: originalByteCount, toByteCount: byteCount)
                return PreparedMedia(url: output, mimeType: plan.mimeType, size: written, reduction: reduction)
            }
            let smaller = size.scaled(by: 0.85)
            guard smaller.longSide >= minimumLongSide, smaller != size else {
                try? FileManager.default.removeItem(at: output)
                throw MediaReencodingError.cannotFitSizeLimit
            }
            size = smaller
        }
    }

    /// これより小さくしないと容量の上限に収まらないなら、収められないとする。
    static let minimumLongSide = 256

    /// ファイルの容量。同じファイルに書き直すので、URLが覚えている値（`resourceValues`）を使わず、毎回読む。
    public static func byteCount(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// - Returns: 書き出した大きさ。縮めるときの丸めで、`size`と1画素ずれることがある。
    private static func write(_ source: CGImageSource, size: PixelSize, type: UTType, quality: Double?, to url: URL) throws -> PixelSize {
        // 縮めた画像を作る関数で、向きを画素に反映して読む。メタデータは付いてこない。
        guard let image = ImageDecoder.thumbnail(of: source, maxPixelSize: size.longSide, dynamicRange: .standard),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw MediaReencodingError.imageFailed }
        let properties: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaReencodingError.imageFailed }
        return PixelSize(width: image.width, height: image.height)
    }
}
