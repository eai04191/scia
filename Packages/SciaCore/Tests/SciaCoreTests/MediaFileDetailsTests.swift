import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import VideoToolbox
@testable import SciaCore

/// ビューアで開いたメディアの、ファイルの中身から読む情報を確かめる。
struct MediaFileDetailsTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MediaFileDetailsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeImage(space spaceName: CFString, bitsPerComponent: Int = 8, alpha: Bool, type: UTType, properties: [CFString: Any] = [:], to url: URL) throws {
        let space = try #require(CGColorSpace(name: spaceName))
        let bitmapInfo: UInt32 = if bitsPerComponent == 16 {
            CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue | CGBitmapInfo.floatComponents.rawValue
        } else {
            alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        }
        let context = try #require(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
    }

    /// 透過のあるPNGは、形式、大きさ、ビット深度、アルファチャンネルを中身から読み、SDRとする。
    @Test func readsPNGWithAlpha() async throws {
        let file = try makeDirectory().appending(path: "image.bin")
        try writeImage(space: CGColorSpace.sRGB, alpha: true, type: .png, to: file)

        let details = try #require(await MediaFileDetails.image(at: file))

        // 拡張子ではなく中身から形式を読む。
        #expect(details.format == "PNG")
        #expect(details.pixelWidth == 8)
        #expect(details.pixelHeight == 4)
        #expect(details.bitDepth == 8)
        #expect(details.hasAlpha == true)
        #expect(details.dynamicRange == .standard)
        #expect((details.byteCount ?? 0) > 0)
    }

    /// Display P3のJPEGは、カラープロファイルの名前を読む。透過のない画像では、アルファチャンネルを出さない。
    @Test func readsColorProfileOfJPEG() async throws {
        let file = try makeDirectory().appending(path: "image.jpg")
        try writeImage(space: CGColorSpace.displayP3, alpha: false, type: .jpeg, to: file)

        let details = try #require(await MediaFileDetails.image(at: file))

        #expect(details.format == "JPEG")
        #expect(details.colorProfile == "Display P3")
        #expect(details.hasAlpha == nil)
    }

    /// 色空間がPQの画像は、PQのHDRとする。
    @Test func readsPQImageAsHDR() async throws {
        let file = try makeDirectory().appending(path: "image.png")
        try writeImage(space: CGColorSpace.itur_2100_PQ, bitsPerComponent: 16, alpha: true, type: .png, to: file)

        let details = try #require(await MediaFileDetails.image(at: file))

        #expect(details.dynamicRange == .pq)
    }

    /// ファイルにEXIFや位置が残っていれば読む。サーバーが消すかどうかによらず、開いたファイルにあれば出す。
    @Test func readsCaptureMetadataWhenPresent() async throws {
        let file = try makeDirectory().appending(path: "photo.jpg")
        try writeImage(space: CGColorSpace.sRGB, alpha: false, type: .jpeg, properties: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:05:01 12:34:56",
                kCGImagePropertyExifLensModel: "iPhone 16 Pro back camera 6.765mm f/1.78",
                kCGImagePropertyExifFNumber: 1.78,
                kCGImagePropertyExifExposureTime: 1.0 / 120,
                kCGImagePropertyExifISOSpeedRatings: [80],
                kCGImagePropertyExifFocalLength: 6.765,
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.6812,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 139.7671,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ], to: file)

        let capture = try #require(await MediaFileDetails.image(at: file)).capture

        #expect(capture.date == "2024:05:01 12:34:56")
        #expect(capture.camera == "Apple iPhone 16 Pro")
        #expect(capture.lens == "iPhone 16 Pro back camera 6.765mm f/1.78")
        #expect(capture.fNumber == 1.78)
        #expect(capture.iso == 80)
        #expect(capture.latitude.map { ($0 * 10_000).rounded() } == 356_812)
        #expect(capture.longitude.map { ($0 * 10_000).rounded() } == 1_397_671)
    }

    /// 機種の名前がメーカーの名前で始まれば、機種だけにする。南と西の位置は負にする。
    @Test func shortensCameraNameAndSignsCoordinates() {
        let capture = MediaFileDetails.capture(of: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 33.86,
                kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.21,
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ])

        #expect(capture.camera == "Canon EOS R5")
        #expect(capture.latitude == -33.86)
        #expect(capture.longitude == -151.21)
    }

    /// メタデータのない画像では、撮影の情報を何も持たない。
    @Test func capturesNothingWithoutMetadata() {
        #expect(MediaFileDetails.capture(of: [:]) == MediaFileDetails.Capture())
    }

    @Test func returnsNilForNonImageFile() async throws {
        let file = try makeDirectory().appending(path: "text.png")
        try Data("not an image".utf8).write(to: file)

        #expect(await MediaFileDetails.image(at: file) == nil)
    }

    /// 動画は、映像と音声のトラックからコーデック、大きさ、フレームレートを読む。端末のファイルなら大きさも読む。
    @Test func readsVideoAndAudioTracks() async throws {
        let details = await MediaFileDetails.movie(AVURLAsset(url: try fixture("video_faststart")))

        #expect(details.videoCodec == "H.264")
        #expect(details.pixelWidth == 320)
        #expect(details.pixelHeight == 180)
        #expect(details.frameRate.map { $0.rounded() } == 30)
        #expect(details.audio == .codec("AAC"))
        #expect(details.dynamicRange == .standard)
        #expect((details.byteCount ?? 0) > 0)
    }

    /// 音声のトラックがない動画は、音声を「なし」にする。読めなかったときと区別する。
    @Test func distinguishesVideoWithoutAudio() async throws {
        let details = await MediaFileDetails.movie(AVURLAsset(url: try fixture("video_long_moov_head")))

        #expect(details.audio == MediaFileDetails.Audio.none)
    }

    /// HLGのHEVCの動画は、HEVCとHLGのHDRとする。
    @Test func readsHLGVideoAsHDR() async throws {
        let file = try makeDirectory().appending(path: "hlg.mov")
        try await writeHLGVideo(to: file)

        let details = await MediaFileDetails.movie(AVURLAsset(url: file))

        #expect(details.videoCodec == "HEVC")
        #expect(details.dynamicRange == .hlg)
    }

    /// 縦に撮った動画は、回転の情報を反映して、見えている向きの大きさにする。
    @Test func appliesRotationToVideoSize() async throws {
        let file = try makeDirectory().appending(path: "portrait.mov")
        try await writeVideo(width: 64, height: 32, codec: .h264, transform: CGAffineTransform(rotationAngle: .pi / 2), to: file)

        let details = await MediaFileDetails.movie(AVURLAsset(url: file))

        #expect(details.pixelWidth == 32)
        #expect(details.pixelHeight == 64)
    }

    @Test func namesUnknownCodecsByTheirFourCharacterCode() {
        #expect(MediaFileDetails.videoCodecName(0x6162_6364) == "abcd")
        #expect(MediaFileDetails.audioCodecName(kAudioFormatOpus) == "Opus")
    }

    private func writeHLGVideo(to url: URL) async throws {
        try await writeVideo(width: 64, height: 64, codec: .hevc, settings: [
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String],
        ], hlg: true, to: url)
    }

    /// 3コマの動画を書く。`hlg`なら、コマにHLGの色の情報を付ける。
    private func writeVideo(width: Int, height: Int, codec: AVVideoCodecType, settings: [String: Any] = [:], transform: CGAffineTransform = .identity, hlg: Bool = false, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var outputSettings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height]
        outputSettings.merge(settings) { _, new in new }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, hlg ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixelBuffer = try #require(buffer)
            if hlg {
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            }
            #expect(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
