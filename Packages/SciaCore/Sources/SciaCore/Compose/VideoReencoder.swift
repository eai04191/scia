public import AVFoundation
import Foundation

public enum VideoReencoder {
    /// 動画の、向きを反映した大きさ、長さ（秒）、フレームレート。
    public struct Info: Sendable, Equatable {
        public let size: PixelSize
        public let duration: Double
        public let frameRate: Double
        public let hasAudio: Bool
    }

    /// 読めなければnil。
    @concurrent
    public static func info(of url: URL) async -> Info? {
        let asset = AVURLAsset(url: url)
        let hasAudio = (try? await asset.loadTracks(withMediaType: .audio).isEmpty == false) ?? false
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (naturalSize, transform, frameRate) = try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate),
              let duration = try? await asset.load(.duration)
        else { return nil }
        let oriented = naturalSize.applying(transform)
        return Info(
            size: PixelSize(width: Int(abs(oriented.width).rounded()), height: Int(abs(oriented.height).rounded())),
            duration: duration.seconds,
            frameRate: Double(frameRate),
            hasAudio: hasAudio
        )
    }

    private static let sdrColorProperties = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// H.264とAACのmp4で書き出す。動画の長さは保つ。音声がないか`removesAudio`なら、音声を書かない。
    ///
    /// HDRの動画は、トーンマッピングしてSDRにする。H.264で書き出す以上、HDRは残せない。
    /// - Parameters:
    ///   - size: 向きを反映した、書き出す大きさ。
    ///   - frameRate: 落とすフレームレート。落とさないならnil。
    ///   - progress: 0から1。書き出した映像の時刻で数える。
    @concurrent
    public static func export(
        _ url: URL,
        size: PixelSize,
        frameRate: Double?,
        bitRate: Int,
        audioBitRate: Int,
        removesAudio: Bool = false,
        destination: URL,
        clock: any Clock<Duration> = SystemTime.clock,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw MediaReencodingError.videoFailed }
        let audioTrack = removesAudio ? nil : try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds

        // 合成では向きだけを反映し、色は元のまま渡す。大きさは書き出す側で縮める。
        // 合成の色空間をBT.709にすると、HLGの値がそのままBT.709の値として出て、トーンマッピングも色域の変換も起きない。
        var configuration = try await AVVideoComposition.Configuration(for: asset)
        if let frameRate {
            // 映像が1本なら、合成は元のトラックのコマの時刻を使い、`frameDuration`を見ない。元の時刻を使わない指定にして、上限のフレームレートにする。
            configuration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
            configuration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))
        }
        let composition = AVVideoComposition(configuration: configuration)

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // 読み出す側で色をBT.709にすると、AVAssetExportSessionのSDRのプリセットと同じ、Appleの標準の変換でSDRにする。
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                AVVideoColorPropertiesKey: Self.sdrColorProperties,
            ]
        )
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw MediaReencodingError.videoFailed }
        reader.add(videoOutput)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoColorPropertiesKey: Self.sdrColorProperties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw MediaReencodingError.videoFailed }
        writer.add(videoInput)

        var audio: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audio = (output, input)
            }
        }

        guard reader.startReading(), writer.startWriting() else { throw MediaReencodingError.videoFailed }
        writer.startSession(atSourceTime: .zero)
        // 映像と音声は、書き出す側が交互に受け取りたがるので、受け取れる方へ順に渡す。片方だけを先に流し切ると、もう片方を待って止まる。
        var isVideoDone = false
        var isAudioDone = audio == nil
        do {
            while !(isVideoDone && isAudioDone) {
                try Task.checkCancellation()
                // 容量不足などで止まると、入力は受け取れないまま戻らないので、待ち続けずに失敗させる。
                guard writer.status != .failed, reader.status != .failed else { throw MediaReencodingError.videoFailed }
                var didAppend = false
                if !isVideoDone, videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        guard videoInput.append(sample) else { throw MediaReencodingError.videoFailed }
                        if duration > 0 {
                            progress(min(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration, 1))
                        }
                    } else {
                        videoInput.markAsFinished()
                        isVideoDone = true
                    }
                    didAppend = true
                }
                if !isAudioDone, let audio, audio.input.isReadyForMoreMediaData {
                    if let sample = audio.output.copyNextSampleBuffer() {
                        guard audio.input.append(sample) else { throw MediaReencodingError.videoFailed }
                    } else {
                        audio.input.markAsFinished()
                        isAudioDone = true
                    }
                    didAppend = true
                }
                if !didAppend {
                    try await clock.sleep(for: .milliseconds(5))
                }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw MediaReencodingError.videoFailed
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw MediaReencodingError.videoFailed }
        progress(1)
    }
}
