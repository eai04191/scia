public import CoreGraphics
public import Foundation

/// 一覧のサムネイルに読む画像と、展開する大きさ。
public struct MediaThumbnailRequest: Equatable, Sendable {
    public let url: URL
    /// 縮めて展開するときの長い辺の最大（ピクセル）。元の画像より大きければ、元の大きさのまま展開する。
    public let maxPixelSize: Int

    public init(url: URL, maxPixelSize: Int) {
        self.url = url
        self.maxPixelSize = maxPixelSize
    }
}

/// サムネイルを読むときの条件。回線と設定から決める。
public struct MediaThumbnailPolicy: Equatable, Sendable {
    /// 元の大きさの画像を読んでよいか。
    public var allowsOriginal: Bool
    /// サーバーが縮めたプレビュー画像（small）を、何倍まで引き伸ばして出してよいか。1なら、少しでも引き伸ばすことになれば元の画像を読む。
    public var upscaleTolerance: Double

    public init(allowsOriginal: Bool, upscaleTolerance: Double) {
        self.allowsOriginal = allowsOriginal
        self.upscaleTolerance = upscaleTolerance
    }
}

/// いまの回線の状態。
public struct NetworkConditions: Equatable, Sendable {
    /// 低データモード。
    public var isConstrained: Bool

    public init(isConstrained: Bool) {
        self.isConstrained = isConstrained
    }
}

/// 一覧のサムネイルに、サーバーが縮めたプレビュー画像と元の画像のどちらを読むかを決める。
///
/// Mastodonのプレビュー画像は面積230,400ピクセル（16:9で640×360）まで縮めてある。
/// 3倍の画面で幅いっぱいに出すと約1,000ピクセル要り、引き伸ばしてぼやけるため、足りなければ元の画像を読む。
/// https://github.com/mastodon/mastodon/blob/main/app/models/media_attachment.rb
public enum MediaThumbnailSelection {
    /// 展開する大きさを切り上げる刻み。枠の大きさが少し変わるたびに読み直さないようにする。
    static let pixelSizeStep = 256
    /// 展開する大きさの上限。ビューアで展開する大きさと揃える。
    static let maxPixelSizeLimit = 4_096

    public static func allowsOriginal(on network: NetworkConditions) -> Bool {
        !network.isConstrained
    }

    /// - Parameters:
    ///   - tileSize: サムネイルの枠の大きさ（ポイント）。空でないこと。
    ///   - displayScale: 画面の1ポイントあたりのピクセル数。
    /// - Returns: 読む画像。読める画像がない種類（音声など）ならnil。
    public static func request(
        for attachment: MediaAttachment,
        tileSize: CGSize,
        displayScale: Double,
        policy: MediaThumbnailPolicy
    ) -> MediaThumbnailRequest? {
        let required = requiredPixelSize(tileSize: tileSize, displayScale: displayScale, aspectRatio: attachment.aspectRatio)
        let maxPixelSize = roundedPixelSize(max(required.width, required.height))
        let url: URL? = switch attachment.type {
        // 動画とGIFは、サーバーが作る静止画がプレビューの1種類しかない。
        case .video, .gifv: attachment.previewUrl
        // 元の画像を読まない条件では、プレビュー画像がなければ読まずにblurhashのぼかしだけを出す。
        case .image: if !policy.allowsOriginal {
            attachment.previewUrl
        } else if usesOriginal(attachment, required: required, policy: policy) {
            attachment.url
        } else {
            attachment.previewUrl ?? attachment.url
        }
        // プレビューのURLが画像とは限らない。
        case .audio, .unknown: nil
        }
        return url.map { MediaThumbnailRequest(url: $0, maxPixelSize: maxPixelSize) }
    }

    private static func usesOriginal(_ attachment: MediaAttachment, required: CGSize, policy: MediaThumbnailPolicy) -> Bool {
        guard attachment.url != nil else { return false }
        guard let small = pixelSize(of: attachment.meta?.small) else {
            // プレビュー画像の大きさを返さないサーバーでは足りるか分からないため、ぼやけない方を選ぶ。
            return true
        }
        if small.width * policy.upscaleTolerance >= required.width, small.height * policy.upscaleTolerance >= required.height {
            return false
        }
        // 元の画像がプレビュー画像より大きくなければ、読み直しても細かくならない。
        if let original = pixelSize(of: attachment.meta?.original), original.width <= small.width, original.height <= small.height {
            return false
        }
        return true
    }

    /// 枠を切り抜いて埋める（aspectFill）のに要る画像の大きさ（ピクセル）。縦横比が分からなければ、枠と同じ比とみなす。
    static func requiredPixelSize(tileSize: CGSize, displayScale: Double, aspectRatio: Double?) -> CGSize {
        let tile = CGSize(width: tileSize.width * displayScale, height: tileSize.height * displayScale)
        guard let aspectRatio, aspectRatio > 0 else { return tile }
        let width = max(tile.width, tile.height * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }

    private static func roundedPixelSize(_ length: CGFloat) -> Int {
        let steps = max(Int((Double(length) / Double(pixelSizeStep)).rounded(.up)), 1)
        return min(steps * pixelSizeStep, maxPixelSizeLimit)
    }

    private static func pixelSize(of size: MediaAttachment.Size?) -> CGSize? {
        guard let width = size?.width, let height = size?.height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
