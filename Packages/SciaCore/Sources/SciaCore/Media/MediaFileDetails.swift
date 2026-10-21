public import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ビューアで開いたメディアの、ファイルの中身から読んだ情報。メディアの情報で、APIの`meta`より詳しく、正確な値を出すのに使う。
/// 決まりはdocs/menus.mdの「メディアのメニュー」にある。読めなかった項目はnil。
public struct MediaFileDetails: Sendable, Equatable {
    public enum DynamicRange: Sendable, Equatable {
        case standard
        /// SDRの画像に、HDRで描くためのゲインマップを足したもの。iPhoneのHDRの写真など。
        case gainMap
        case pq
        case hlg
    }

    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// 中身から見た形式。拡張子ではなく、ImageIOやコーデックが読んだ種類。
    public var format: String?
    public var byteCount: Int?
    /// 色のプロファイルの名前（`Display P3`など）。
    public var colorProfile: String?
    /// 色の成分ごとのビット数。
    public var bitDepth: Int?
    public var dynamicRange: DynamicRange?
    /// アルファチャンネルを持つ。持たなければnil（出さない）。
    public var hasAlpha: Bool?
    /// 映像のコーデック。
    public var videoCodec: String?
    public var frameRate: Double?
    /// 音声のコーデック。音声のトラックがなければ`.none`、読めなければnil。
    public var audio: Audio?

    public enum Audio: Sendable, Equatable {
        case none
        case codec(String)
    }

    /// 撮影したときの情報。画像のファイルにEXIFやGPSが残っていれば読む。サーバーが消していることも多い。
    public var capture = Capture()

    public struct Capture: Sendable, Equatable {
        /// EXIFのままの`2024:05:01 12:34:56`。
        public var date: String?
        /// メーカーと機種。機種がメーカーの名前で始まれば、機種だけにする。
        public var camera: String?
        public var lens: String?
        public var fNumber: Double?
        /// 秒。
        public var exposureTime: Double?
        public var iso: Int?
        /// mm。
        public var focalLength: Double?
        /// 緯度と経度。南と西は負。
        public var latitude: Double?
        public var longitude: Double?

        public init() {}
    }

    public init() {}

    // MARK: 画像

    /// 端末に置いた画像のファイルから読む。画像として読めなければnil。
    @concurrent
    public static func image(at file: URL) async -> MediaFileDetails? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        var details = MediaFileDetails()
        details.byteCount = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        details.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        details.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        details.format = CGImageSourceGetType(source).flatMap { UTType($0 as String) }.flatMap(imageFormatName(of:))
        details.colorProfile = properties[kCGImagePropertyProfileName] as? String
        details.bitDepth = properties[kCGImagePropertyDepth] as? Int
        details.hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) == true ? true : nil
        details.dynamicRange = imageDynamicRange(of: source)
        details.capture = capture(of: properties)
        return details
    }

    static func capture(of properties: [CFString: Any]) -> Capture {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        var capture = Capture()
        capture.date = nonEmpty(exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime])
        let make = nonEmpty(tiff[kCGImagePropertyTIFFMake])
        let model = nonEmpty(tiff[kCGImagePropertyTIFFModel])
        capture.camera = switch (make, model) {
        case let (make?, model?): model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        case let (make, model): make ?? model
        }
        capture.lens = nonEmpty(exif[kCGImagePropertyExifLensModel])
        capture.fNumber = positive(exif[kCGImagePropertyExifFNumber])
        capture.exposureTime = positive(exif[kCGImagePropertyExifExposureTime])
        capture.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        capture.focalLength = positive(exif[kCGImagePropertyExifFocalLength])
        if let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            capture.latitude = gps[kCGImagePropertyGPSLatitudeRef] as? String == "S" ? -latitude : latitude
            capture.longitude = gps[kCGImagePropertyGPSLongitudeRef] as? String == "W" ? -longitude : longitude
        }
        return capture
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number > 0 else { return nil }
        return number
    }

    /// 形式の名前。拡張子を大文字にし、`jpg`と`jpeg`は`JPEG`と書く。
    static func imageFormatName(of type: UTType) -> String? {
        guard let ext = type.preferredFilenameExtension?.lowercased() else { return nil }
        return ext == "jpg" || ext == "jpeg" ? "JPEG" : ext.uppercased()
    }

    /// ゲインマップがあればゲインマップのHDR、色空間がPQかHLGならそのHDR、どれでもなければSDR。
    private static func imageDynamicRange(of source: CGImageSource) -> DynamicRange {
        for type in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] where CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil {
            return .gainMap
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary),
              let space = image.colorSpace
        else { return .standard }
        if CGColorSpaceIsPQBased(space) { return .pq }
        if CGColorSpaceIsHLGBased(space) { return .hlg }
        return .standard
    }

    // MARK: 動画と音声

    /// 再生している動画や音声のトラックから読む。ストリーミングで読むため、端末のファイルでなければファイルの大きさは出さない。
    public static func movie(_ asset: AVURLAsset) async -> MediaFileDetails {
        var details = MediaFileDetails()
        if asset.url.isFileURL {
            details.byteCount = (try? asset.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
        if let video = try? await asset.loadTracks(withMediaType: .video).first,
           let (naturalSize, transform, frameRate, descriptions) = try? await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions) {
            // 縦に撮った動画は、回転前の大きさに向きの情報が付いているため、見えている向きの大きさにする。Mastodonの`meta`と同じ。
            let size = naturalSize.applying(transform)
            details.pixelWidth = Int(abs(size.width).rounded())
            details.pixelHeight = Int(abs(size.height).rounded())
            details.frameRate = frameRate > 0 ? Double(frameRate) : nil
            if let description = descriptions.first {
                details.videoCodec = videoCodecName(CMFormatDescriptionGetMediaSubType(description))
                details.dynamicRange = videoDynamicRange(of: description)
            }
        }
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
            if let track = audioTracks.first, let description = try? await track.load(.formatDescriptions).first {
                details.audio = .codec(audioCodecName(CMFormatDescriptionGetMediaSubType(description)))
            } else if audioTracks.isEmpty {
                details.audio = MediaFileDetails.Audio.none
            }
        }
        return details
    }

    static func videoCodecName(_ subtype: FourCharCode) -> String {
        switch subtype {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, FourCharCode(fourCC: "hev1"): "HEVC"
        case kCMVideoCodecType_AV1: "AV1"
        case kCMVideoCodecType_VP9: "VP9"
        default: subtype.fourCCString
        }
    }

    static func audioCodecName(_ subtype: FourCharCode) -> String {
        switch subtype {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: "AAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatAppleLossless: "ALAC"
        default: subtype.fourCCString
        }
    }

    private static func videoDynamicRange(of description: CMFormatDescription) -> DynamicRange {
        let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        if transfer == String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ) { return .pq }
        if transfer == String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG) { return .hlg }
        return .standard
    }
}

private extension FourCharCode {
    init(fourCC: String) {
        self = fourCC.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// 知らないコーデックは、4文字のコードをそのまま出す。
    var fourCCString: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
