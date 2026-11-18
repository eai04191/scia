// 「投稿の見た目」の見本の動くアイコンのコマを、HEVCの動画に書き出す（Tools/render-preview-avatar.pyから呼ぶ）。
// コマごとの長さは、動画の表示時刻（1/100秒の単位）に持たせ、アプリはそれを読んでAPNGにする。
// エンコーダーはソフトウェアのものを名指しする。GitHub Actionsの仮想マシンではハードウェアのエンコーダーが使えないことがあり、マシンによって違う動画にもなるため。
//
// 使い方: xcrun --sdk macosx swift Tools/encode-preview-avatar.swift <出力.mp4> <長さ(1/100秒)>:<コマのPNG>...
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import VideoToolbox

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count > 2 else { fail("使い方: encode-preview-avatar.swift <出力.mp4> <長さ(1/100秒)>:<コマのPNG>...") }
let output = URL(fileURLWithPath: arguments[1])
let frames: [(centiseconds: Int64, image: CGImage)] = arguments[2...].map { argument in
    let parts = argument.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let centiseconds = Int64(parts[0]), centiseconds > 0,
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: String(parts[1])) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("コマを読めません: \(argument)") }
    return (centiseconds, image)
}
let width = frames[0].image.width
let height = frames[0].image.height

try? FileManager.default.removeItem(at: output)
let writer: AVAssetWriter
do {
    writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
} catch {
    fail("動画を書き出せません: \(error)")
}
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EncoderID as String: "com.apple.videotoolbox.videoencoder.hevc.vcp"],
    AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.9],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
input.expectsMediaDataInRealTime = false
input.mediaTimeScale = 100
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
guard writer.startWriting() else { fail("動画を書き始められません: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)

let context = CIContext()
var time: Int64 = 0
for frame in frames {
    while !input.isReadyForMoreMediaData {
        // 書き出しに失敗すると、受け付けられる状態に戻らないため、待っている間にも確かめる。
        guard writer.status == .writing else { fail("動画を書けません: \(String(describing: writer.error))") }
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard let pool = adaptor.pixelBufferPool else { fail("画像の置き場所を作れません") }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else { fail("画像の置き場所を作れません") }
    context.render(CIImage(cgImage: frame.image), to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: time, timescale: 100)) else {
        fail("コマを書けません: \(String(describing: writer.error))")
    }
    time += frame.centiseconds
}
input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: time, timescale: 100))
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()
guard writer.status == .completed else { fail("動画を書き終えられません: \(String(describing: writer.error))") }
