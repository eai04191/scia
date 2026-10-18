public import Foundation
import AVFoundation
import ImageIO

/// 送るメディアから、撮った場所の位置情報を除く。サーバーが除くかはAPIで分からないので、端末で除く。
///
/// 作り直すときは位置情報を書かない（`ImageReencoder`と`VideoReencoder`はメタデータを書き出さない）ので、ここで扱うのは元のまま送るファイル。
/// 画質を落とさないよう、画像も動画も中身は作り直さず、位置情報の項目だけを除いて書き直す。
public enum LocationRemover {
    /// 撮った場所を表すメタデータの項目。EXIFのGPSのほか、XMPやIPTCに書く撮影場所と、都市・州・国・場所の名前。
    static let imageLocationPathPrefixes = [
        "exif:GPS",
        "Iptc4xmpExt:LocationCreated",
        "Iptc4xmpExt:LocationShown",
        "Iptc4xmpCore:Location",
        "Iptc4xmpCore:CountryCode",
        "photoshop:City",
        "photoshop:State",
        "photoshop:Country",
    ]

    /// 画像に位置情報があれば、位置情報の項目だけを除いて`destination`に書き出す。なければnil。
    ///
    /// ImageIOの`kCGImageMetadataShouldExcludeGPS`は使わない。Macで試すと、HEICでは位置情報が残り、JPEGでは向き（EXIFのOrientation）まで消えて上下が逆になった。
    /// メタデータを取り出して位置情報の項目だけを外し、合わせずに置き換える（`kCGImageDestinationMergeMetadata`をfalse）と、HEICでもJPEGでも、
    /// 位置情報が消えて向きは残り、表示される画素は元と同じだった。
    @concurrent
    public static func removingLocation(fromImage url: URL, destination: URL) async throws -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { throw MediaReencodingError.imageFailed }
        guard let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let metadata = CGImageMetadataCreateMutableCopy(original) else { return nil }
        // いちばん上の項目だけを見る。撮影場所のような入れ子の項目は、いちばん上の項目ごと除く。
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            if imageLocationPathPrefixes.contains(where: { (path as String).hasPrefix($0) }) {
                paths.append(path as String)
            }
            return true
        }
        guard !paths.isEmpty else { return nil }
        for path in paths {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else { throw MediaReencodingError.imageFailed }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
        guard CGImageDestinationCopyImageSource(output, source, options as CFDictionary, nil) else { throw MediaReencodingError.imageFailed }
        return destination
    }

    /// 動画に位置情報がありそうなら、映像と音声は作り直さずに、その2種類のトラックだけを組み直して`destination`に書き出す。なければnil。
    ///
    /// 位置情報は、動画全体のメタデータのほか、トラックのメタデータや、時刻ごとのメタデータのトラックにも書けるので、どれかにあれば組み直す。
    /// 組み直すと、動画全体とトラックのメタデータと、時刻ごとのメタデータのトラックは付いてこない。
    @concurrent
    public static func removingLocation(fromVideo url: URL, destination: URL) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        var items = try await asset.load(.metadata)
        for track in tracks {
            items += try await track.load(.metadata)
        }
        let hasTimedMetadata = !(try await asset.loadTracks(withMediaType: .metadata)).isEmpty
        guard hasTimedMetadata || items.contains(where: isLocation) else { return nil }
        let composition = AVMutableComposition()
        for track in tracks where track.mediaType == .video || track.mediaType == .audio {
            let (timeRange, transform) = try await track.load(.timeRange, .preferredTransform)
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MediaReencodingError.videoFailed
            }
            try copy.insertTimeRange(timeRange, of: track, at: timeRange.start)
            copy.preferredTransform = transform
        }
        // 組み直した動画には、動画全体のメタデータも付いてこない。
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw MediaReencodingError.videoFailed }
        try? FileManager.default.removeItem(at: destination)
        try await session.export(to: destination, as: destination.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        return destination
    }

    /// 場所を表すメタデータの項目。座標のほか、場所の名前（共通のキーを持たない）も含める。
    private static func isLocation(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyLocation { return true }
        let identifier = item.identifier?.rawValue.lowercased() ?? ""
        return identifier.contains("location") || identifier.contains("gps")
    }
}
