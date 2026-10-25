public import CoreGraphics
public import Foundation

/// 一覧のサムネイルに読む画像と、展開する大きさ。
public struct MediaThumbnailRequest: Equatable, Sendable {
    /// 読むファイル。`source`が`videoFrame`なら動画。
    public let url: URL
    /// 縮めて展開するときの長い辺の最大（ピクセル）。元の画像より大きければ、元の大きさのまま展開する。
    public let maxPixelSize: Int
    public let source: Source

    public enum Source: Equatable, Sendable {
        case image
        /// 動画の先頭を読んで、最初のフレームを作る。作れなければ`fallback`の画像（サーバーのプレビュー）を読む。
        case videoFrame(fallback: URL)
    }

    public init(url: URL, maxPixelSize: Int, source: Source = .image) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.source = source
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
    /// モバイル通信や、インターネット共有のように通信量に限りのある回線。
    public var isExpensive: Bool

    public init(isConstrained: Bool, isExpensive: Bool) {
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
    }
}

/// 一覧のサムネイルに、サーバーが縮めたプレビュー画像と元の画像のどちらを読むかを決める。
///
/// Mastodonのプレビュー画像は面積230,400ピクセル（16:9で640×360）まで縮めてある。
/// 3倍の画面で幅いっぱいに出すと約1,000ピクセル要り、引き伸ばしてぼやけるため、足りなければ元の画像を読む。
/// 動画とGIFのプレビューは長い辺640ピクセルまでのため、足りなければ元の動画の先頭を読んで最初のフレームを作る（`VideoFirstFrame`）。
/// https://github.com/mastodon/mastodon/blob/main/app/models/media_attachment.rb
public enum MediaThumbnailSelection {
    /// 展開する大きさを切り上げる刻み。枠の大きさが少し変わるたびに読み直さないようにする。
    static let pixelSizeStep = 256
    /// 展開する大きさの上限。ビューアで展開する大きさと揃える。
    static let maxPixelSizeLimit = 4_096

    /// 低データモードでは、設定によらず元の画像を読まない。
    /// - Parameter usesOriginalOnExpensiveNetwork: モバイル通信などでも元の画像を読む設定。
    public static func allowsOriginal(on network: NetworkConditions, usesOriginalOnExpensiveNetwork: Bool) -> Bool {
        !network.isConstrained && (!network.isExpensive || usesOriginalOnExpensiveNetwork)
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
        if let video = videoFrameSource(of: attachment, required: required, policy: policy) {
            return MediaThumbnailRequest(url: video.url, maxPixelSize: maxPixelSize, source: .videoFrame(fallback: video.fallback))
        }
        let url: URL? = switch attachment.type {
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

    /// 動画とGIFで、サーバーのプレビューの代わりに動画の最初のフレームを作るなら、その動画とプレビューのURL。
    ///
    /// サーバーが動画から作るプレビューは、動画の0秒目のフレームを縮めたもの。作者がサムネイルを付けていれば、プレビューはその画像になる。
    /// 作者が選んだ画像を差し替えないよう、プレビューが動画から作ったものだと分かるときだけ置き換える。
    /// - 他のサーバーの投稿で作者が付けていれば、`previewRemoteUrl`が入る
    /// - 自分のサーバーの投稿で作者が付けていれば、プレビューは`media_attachments/thumbnails/…/original/…`になる。
    ///   動画から作ったものは`media_attachments/files/…/small/…`になる。サーバーがファイルを消した他のサーバーの投稿では
    ///   `/media_proxy/<id>/small`になり、作者が付けていなければ動画から作ったものへ転送される
    /// https://github.com/mastodon/mastodon/blob/main/app/serializers/rest/media_attachment_serializer.rb
    /// https://github.com/mastodon/mastodon/blob/main/app/controllers/media_proxy_controller.rb
    private static func videoFrameSource(of attachment: MediaAttachment, required: CGSize, policy: MediaThumbnailPolicy) -> (url: URL, fallback: URL)? {
        guard attachment.type == .video || attachment.type == .gifv,
              policy.allowsOriginal,
              let video = attachment.url,
              let preview = attachment.previewUrl,
              isGeneratedFromVideo(preview: preview, previewRemoteUrl: attachment.previewRemoteUrl),
              usesOriginal(attachment, required: required, policy: policy)
        else { return nil }
        return (video, preview)
    }

    static func isGeneratedFromVideo(preview: URL, previewRemoteUrl: URL?) -> Bool {
        guard previewRemoteUrl == nil else { return false }
        let components = preview.pathComponents
        return components.last == "small" || components.dropLast().last == "small"
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

    /// 縦横比はサーバーが返す幅と高さから決まり、極端に細長いと`length`が整数に収まらない。整数に直す前に上限で止める。
    private static func roundedPixelSize(_ length: CGFloat) -> Int {
        let steps = max(Int((min(Double(length), Double(maxPixelSizeLimit)) / Double(pixelSizeStep)).rounded(.up)), 1)
        return min(steps * pixelSizeStep, maxPixelSizeLimit)
    }

    private static func pixelSize(of size: MediaAttachment.Size?) -> CGSize? {
        guard let width = size?.width, let height = size?.height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
