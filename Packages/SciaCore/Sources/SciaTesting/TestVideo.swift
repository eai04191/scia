public import Foundation
import AVFoundation
import CoreVideo
import Testing

/// テストで送ったり作り直したりする動画を書き出す。
public enum TestVideo {
    public struct WriteError: Error {}

    /// 1秒の塗りつぶしのH.264の動画を書き出す。`withAudio`なら、1秒の無音のAACも付ける。
    public static func write(width: Int, height: Int, withAudio: Bool, to url: URL) async throws {
        guard withAudio else {
            try await writeSilentVideo(width: width, height: height, to: url)
            return
        }
        let video = url.deletingLastPathComponent().appending(path: "video-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: video) }
        try await writeSilentVideo(width: width, height: height, to: video)
        try await addingSilentAudio(to: video, destination: url)
    }

    /// `video`に1秒の無音のAACを足し、映像を作り直さずに`destination`へ書き出す。
    public static func addingSilentAudio(to video: URL, destination: URL) async throws {
        let audioURL = video.deletingLastPathComponent().appending(path: "silence-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        do {
            let file = try AVAudioFile(
                forWriting: audioURL,
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100) else { throw WriteError() }
            buffer.frameLength = 44_100
            try file.write(from: buffer)
        }
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audioURL)
        let duration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let composition = AVMutableComposition()
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw WriteError() }
        try videoOut.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try audioOut.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)), of: audioTrack, at: .zero)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw WriteError() }
        try await session.export(to: destination, as: destination.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
    }

    private static func writeSilentVideo(width: Int, height: Int, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw WriteError() }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            try await waitUntil { input.isReadyForMoreMediaData }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let pixelBuffer = buffer else { throw WriteError() }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(frame * 8), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else { throw WriteError() }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw WriteError() }
    }
}
