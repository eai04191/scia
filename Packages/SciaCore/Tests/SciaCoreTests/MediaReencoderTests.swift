import AVFoundation
import Foundation
import ImageIO
import SciaTesting
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import SciaCore

struct MediaReencoderTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MediaReencoderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 塗りつぶした画像を書き出す。`orientation`と位置情報も付けられる。
    /// - Parameter noise: 塗りつぶさず、画素ごとにばらばらの色にする。縮めると容量が減る画像にするため。
    private func writeImage(width: Int, height: Int, type: UTType, alpha: Bool = false, noise: Bool = false, orientation: Int = 1, gps: Bool = false, to url: URL) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise, let data = context.data {
            let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            var generator = SystemRandomNumberGenerator()
            for index in 0..<(context.bytesPerRow * height) {
                bytes[index] = UInt8.random(in: 0...255, using: &generator)
            }
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 35.68, kCGImagePropertyGPSLatitudeRef: "N"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// 90度回した向きの写真は、見えるとおりの幅と高さで数え、向きを画素に反映して縮める。位置情報は残さない。
    @Test func shrinksRotatedPhotoAndDropsLocation() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "rotated.jpg")
        try writeImage(width: 400, height: 300, type: .jpeg, orientation: 6, gps: true, to: source)
        let size = try #require(ImageReencoder.size(of: source))
        #expect(size == PixelSize(width: 300, height: 400))

        let plan = ImagePlan(mimeType: "image/jpeg", size: PixelSize(width: 150, height: 200), sizeBySetting: PixelSize(width: 150, height: 200), exceedsSizeLimit: false)
        let prepared = try await ImageReencoder.reencode(source, plan: plan, originalSize: size, sizeLimit: nil, quality: 0.85, destination: directory.appending(path: "out"))

        #expect(prepared.size == PixelSize(width: 150, height: 200))
        #expect(prepared.reduction == nil)
        let output = try properties(of: prepared.url)
        #expect(output[kCGImagePropertyPixelWidth] as? Int == 150)
        #expect(output[kCGImagePropertyPixelHeight] as? Int == 200)
        #expect((output[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(output[kCGImagePropertyGPSDictionary] == nil)
    }

    /// サーバーが受け付けるなら、HEICで作り直す。
    @Test func reencodesAsHEIC() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "photo.jpg")
        try writeImage(width: 800, height: 600, type: .jpeg, noise: true, to: source)
        let plan = ImagePlan(mimeType: "image/heic", size: PixelSize(width: 400, height: 300), sizeBySetting: PixelSize(width: 400, height: 300), exceedsSizeLimit: false)
        let prepared = try await ImageReencoder.reencode(source, plan: plan, originalSize: PixelSize(width: 800, height: 600), sizeLimit: nil, quality: 0.85, destination: directory.appending(path: "out"))
        #expect(prepared.url.pathExtension == "heic")
        let imageSource = try #require(CGImageSourceCreateWithURL(prepared.url as CFURL, nil))
        #expect(CGImageSourceGetType(imageSource) as String? == UTType.heic.identifier)
        #expect(prepared.size == PixelSize(width: 400, height: 300))
    }

    /// 処理できない形式を、大きさを変えずにJPEGへ作り直しただけなら、縮めたとは知らせない。
    @Test func formatOnlyConversionIsNotAReduction() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "photo.heic")
        try writeImage(width: 400, height: 300, type: .heic, to: source)
        let original = PixelSize(width: 400, height: 300)
        let plan = ImagePlan(mimeType: "image/jpeg", size: original, sizeBySetting: original, exceedsSizeLimit: false)
        let prepared = try await ImageReencoder.reencode(source, plan: plan, originalSize: original, sizeLimit: nil, quality: 0.85, destination: directory.appending(path: "out"))
        #expect(prepared.url.pathExtension == "jpeg")
        #expect(prepared.size == original)
        #expect(prepared.reduction == nil)
    }

    /// 画像の画素。向きを反映せずに読む。
    private func pixels(of url: URL) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(image.dataProvider?.data as Data?)
    }

    /// 元のまま送る写真から、位置情報だけを除く。向きと画素は変えない。
    @Test(arguments: [UTType.jpeg, UTType.heic])
    func removesLocationKeepingOrientationAndPixels(type: UTType) async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "photo.\(type.preferredFilenameExtension ?? "img")")
        try writeImage(width: 320, height: 240, type: type, noise: true, orientation: 6, gps: true, to: source)
        #expect(try properties(of: source)[kCGImagePropertyGPSDictionary] != nil)

        let output = try #require(await LocationRemover.removingLocation(fromImage: source, destination: directory.appending(path: "clean.\(type.preferredFilenameExtension ?? "img")")))

        let cleaned = try properties(of: output)
        #expect(cleaned[kCGImagePropertyGPSDictionary] == nil)
        #expect(cleaned[kCGImagePropertyOrientation] as? Int == 6)
        #expect(try pixels(of: output) == pixels(of: source))
    }

    private func metadataTag(_ path: String, in url: URL) throws -> CGImageMetadataTag? {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        return CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString)
    }

    /// EXIFのGPSのほかに、XMPやIPTCに書いた撮った場所の名前も除く。EXIFのGPSがなくても除く。
    @Test func removesLocationNamesInXMPAndIPTC() async throws {
        let directory = try makeDirectory()
        let plain = directory.appending(path: "plain.jpg")
        try writeImage(width: 32, height: 24, type: .jpeg, to: plain)
        let source = directory.appending(path: "named.jpg")
        let imageSource = try #require(CGImageSourceCreateWithURL(plain as CFURL, nil))
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "photoshop:City" as CFString, "千代田区" as CFString))
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "Iptc4xmpCore:Location" as CFString, "東京駅" as CFString))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        #expect(CGImageDestinationCopyImageSource(destination, imageSource, [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary, nil))
        #expect(try metadataTag("photoshop:City", in: source) != nil)

        let output = try #require(await LocationRemover.removingLocation(fromImage: source, destination: directory.appending(path: "clean.jpg")))

        #expect(try metadataTag("photoshop:City", in: output) == nil)
        #expect(try metadataTag("Iptc4xmpCore:Location", in: output) == nil)
    }

    /// 位置情報のない画像は、書き直さない。
    @Test func leavesImageWithoutLocationAlone() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "photo.jpg")
        try writeImage(width: 32, height: 24, type: .jpeg, to: source)
        #expect(try await LocationRemover.removingLocation(fromImage: source, destination: directory.appending(path: "clean.jpg")) == nil)
    }

    /// PNGはPNGのまま縮め、透過を残す。
    @Test func keepsPNGTransparency() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "clear.png")
        try writeImage(width: 400, height: 400, type: .png, alpha: true, to: source)
        let plan = ImagePlan(mimeType: "image/png", size: PixelSize(width: 200, height: 200), sizeBySetting: PixelSize(width: 200, height: 200), exceedsSizeLimit: false)
        let prepared = try await ImageReencoder.reencode(source, plan: plan, originalSize: PixelSize(width: 400, height: 400), sizeLimit: nil, quality: 0.85, destination: directory.appending(path: "out"))
        #expect(prepared.url.pathExtension == "png")
        #expect(try properties(of: prepared.url)[kCGImagePropertyHasAlpha] as? Bool == true)
    }

    /// 容量の上限に収まらなければ、さらに縮め、サーバーのために縮めたと記録する。
    @Test func shrinksFurtherToFitTheSizeLimit() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "large.png")
        try writeImage(width: 1000, height: 1000, type: .png, noise: true, to: source)
        let original = PixelSize(width: 1000, height: 1000)
        let plan = ImagePlan(mimeType: "image/png", size: original, sizeBySetting: original, exceedsSizeLimit: true)
        let first = try await ImageReencoder.reencode(source, plan: plan, originalSize: original, sizeLimit: nil, quality: 0.85, destination: directory.appending(path: "unlimited"))
        let firstByteCount = try #require(try first.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let prepared = try await ImageReencoder.reencode(source, plan: plan, originalSize: original, sizeLimit: firstByteCount / 2, quality: 0.85, destination: directory.appending(path: "limited"))
        let reduction = try #require(prepared.reduction)
        #expect(reduction.toSize.longSide < 1000)
        #expect(reduction.toByteCount <= firstByteCount / 2)
    }

    // MARK: - 動画

    enum VideoLocation {
        case none
        /// iPhoneのカメラと同じく、撮った場所の座標を動画全体のQuickTimeのメタデータに書く。
        case coordinates
        /// 場所の名前だけを書く。共通のキー（commonKey）を持たない。
        case name
        /// 座標を、映像のトラックのメタデータにだけ書く。
        case trackCoordinates
    }

    private func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// 1秒の塗りつぶしの動画を書き出す。
    private func writeVideo(width: Int, height: Int, frameRate: Int = 30, location: VideoLocation = .none, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
        switch location {
        case .none, .trackCoordinates: break
        case .coordinates: writer.metadata = [metadataItem(.quickTimeMetadataLocationISO6709, "+35.6812+139.7671/")]
        case .name: writer.metadata = [metadataItem(.quickTimeMetadataLocationName, "東京駅")]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        if location == .trackCoordinates {
            input.metadata = [metadataItem(.quickTimeMetadataLocationISO6709, "+35.6812+139.7671/")]
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameRate {
            try await waitUntil { input.isReadyForMoreMediaData }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(frame * 8), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            #expect(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test func exportsSmallerH264KeepingTheDuration() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "source.mp4")
        try await writeVideo(width: 640, height: 360, to: source)
        let sourceInfo = try #require(await VideoReencoder.info(of: source))
        #expect(sourceInfo.size == PixelSize(width: 640, height: 360))

        let output = directory.appending(path: "out.mp4")
        let lastProgress = LockedValue(0.0)
        try await VideoReencoder.export(
            source, size: PixelSize(width: 320, height: 180), frameRate: nil, bitRate: 300_000, audioBitRate: 128_000, destination: output
        ) { fraction in lastProgress.set(fraction) }

        let info = try #require(await VideoReencoder.info(of: output))
        #expect(info.size == PixelSize(width: 320, height: 180))
        #expect(abs(info.duration - sourceInfo.duration) < 0.1)
        #expect(lastProgress.get() == 1)
        #expect(!info.hasAudio)
    }

    /// 動画全体と、各トラックのメタデータに、場所の項目があるか。
    private func hasLocation(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        var items = try await asset.load(.metadata)
        for track in try await asset.load(.tracks) {
            items += try await track.load(.metadata)
        }
        return items.contains { $0.identifier == .quickTimeMetadataLocationISO6709 || $0.identifier == .quickTimeMetadataLocationName }
    }

    /// 元のまま送る動画から、映像を作り直さずに位置情報を除く。場所の名前だけのときも、トラックにだけ書いてあるときも除く。
    @Test(arguments: [VideoLocation.coordinates, .name, .trackCoordinates])
    func removesLocationFromVideoWithoutReencoding(location: VideoLocation) async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "clip.mov")
        try await writeVideo(width: 320, height: 180, location: location, to: source)
        #expect(try await hasLocation(source))

        let output = try #require(await LocationRemover.removingLocation(fromVideo: source, destination: directory.appending(path: "clean.mov")))

        #expect(try await !hasLocation(output))
        let info = try #require(await VideoReencoder.info(of: output))
        #expect(info.size == PixelSize(width: 320, height: 180))
        // 作り直していないので、映像の容量はほとんど変わらない。
        let ratio = Double(ImageReencoder.byteCount(of: output)) / Double(ImageReencoder.byteCount(of: source))
        #expect(ratio > 0.9 && ratio < 1.1)
    }

    /// 縮めて書き出した動画には、位置情報を書かない。
    @Test func exportedVideoHasNoLocation() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "clip.mov")
        try await writeVideo(width: 320, height: 180, location: .coordinates, to: source)
        let output = directory.appending(path: "small.mp4")
        try await VideoReencoder.export(source, size: PixelSize(width: 160, height: 90), frameRate: nil, bitRate: 200_000, audioBitRate: 128_000, destination: output) { _ in }
        #expect(try await !hasLocation(output))
    }

    /// 上限のフレームレートを決めたら、元のコマの時刻に従わずに、そのフレームレートで書き出す。
    @Test func capsTheFrameRateOfASingleTrack() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "fast.mp4")
        try await writeVideo(width: 320, height: 180, frameRate: 60, to: source)
        #expect(try #require(await VideoReencoder.info(of: source)).frameRate > 55)

        let output = directory.appending(path: "capped.mp4")
        try await VideoReencoder.export(
            source, size: PixelSize(width: 320, height: 180), frameRate: 30, bitRate: 300_000, audioBitRate: 128_000, destination: output
        ) { _ in }
        let info = try #require(await VideoReencoder.info(of: output))
        #expect(info.frameRate <= 31)
    }

    /// HLGの試験動画の、左から並べた灰色の帯の信号の値。HLGの0.75は、BT.2408の参照白（203 nit）。
    private static let hlgLevels: [Double] = [0.25, 0.5, 0.75, 0.9, 1.0]

    /// iPhoneのHDR動画と同じ、BT.2020とHLGの10bitのHEVCで、灰色の帯を並べた動画を書き出す。
    private func writeHLGVideo(width: Int, height: Int, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            try await waitUntil { input.isReadyForMoreMediaData }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &buffer)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            // 10bitのvideo rangeで、16bitの上位10bitに入れる。灰色なので、色差は中央の512。
            let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)).assumingMemoryBound(to: UInt16.self)
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / 2
            for row in 0..<height {
                for column in 0..<width {
                    let level = Self.hlgLevels[column * Self.hlgLevels.count / width]
                    luma[row * lumaStride + column] = UInt16((64 + 876 * level).rounded()) << 6
                }
            }
            let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)).assumingMemoryBound(to: UInt16.self)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / 2
            for index in 0..<(chromaStride * height / 2) {
                chroma[index] = 512 << 6
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            #expect(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    /// SDRの動画の最初のコマで、帯ごとの真ん中の明るさを、黒0から白1で読む。
    private func bandLuma(of url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let pixelBuffer = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let row = CVPixelBufferGetHeight(pixelBuffer) / 2
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        return Self.hlgLevels.indices.map { band in
            let column = (2 * band + 1) * width / (2 * Self.hlgLevels.count)
            return (Double(luma[row * stride + column]) - 16) / 219
        }
    }

    /// HDRの動画は、トーンマッピングしてSDRに書き出す。HLGの値をそのままBT.709の値として書かない。
    ///
    /// 正しい結果は、Appleの標準のSDRへの変換とする。AVAssetExportSessionのH.264のプリセットで書き出したものを、同じ試験動画から作って比べる。
    /// macOS 27では、この変換はHLGの0.25、0.5、0.75、0.9、1.0を、BT.709の0.22、0.38、0.60、0.81、1.00にする。参照白を6割ほどに抑え、その上の明るさの差を残す。
    /// VTPixelTransferSessionで出力の色をBT.709にしたときも同じ値になる。CIToneMapHeadroom（元のヘッドルーム4.93、目標1）は0.75、0.92、1.00で、参照白を明るく残す代わりに、ハイライトの差が小さくなる。
    /// 色を変えずにHLGの値を素通しすると、0.75、0.90、1.00がそのまま出て、全体が明るく白っぽくなる。
    @Test func tonemapsHLGVideoToSDR() async throws {
        let directory = try makeDirectory()
        let source = directory.appending(path: "hlg.mov")
        try await writeHLGVideo(width: 320, height: 180, to: source)

        let reference = directory.appending(path: "reference.mp4")
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPreset1280x720))
        try await session.export(to: reference, as: .mp4)
        let expected = try await bandLuma(of: reference)
        // 比べる基準が素通しになっていないこと。
        #expect(expected[2] < 0.7)

        let output = directory.appending(path: "sdr.mp4")
        try await VideoReencoder.export(source, size: PixelSize(width: 320, height: 180), frameRate: nil, bitRate: 1_000_000, audioBitRate: 128_000, destination: output) { _ in }
        let actual = try await bandLuma(of: output)
        for (actualLuma, expectedLuma) in zip(actual, expected) {
            #expect(abs(actualLuma - expectedLuma) < 0.03, "書き出した明るさ \(actual)、Appleの変換 \(expected)")
        }
    }
}

/// 別のスレッドから書く値。
private final class LockedValue<Value: Sendable>: Sendable {
    private let value: Mutex<Value>

    init(_ value: Value) {
        self.value = Mutex(value)
    }

    func get() -> Value { value.withLock { $0 } }
    func set(_ newValue: Value) { value.withLock { $0 = newValue } }
}
