#if DEBUG
import AVFoundation
import SciaCore
import UIKit

/// ビューアを確かめるための、通信せずに表示できるダミーの添付ファイル。
/// 画像は端末で描いてdata URLにする。画像の読み込みはURLSessionで行い、data URLもそのまま読めるため。
/// 動画はdata URLでは再生できないため、端末で短いmp4を書き出し、ファイルのURLで渡す。
enum DummyMedia {
    private struct Spec {
        let size: CGSize
        let color: UIColor
        let label: String
        let description: String?
        /// 背景を透明にし、色の部分を半透明の円にする。PNGで渡す。
        var transparent = false
    }

    /// 形の違う4枚。一覧の並べ方と、ビューアでの開閉や拡大を、縦長・横長・正方形・細長で比べられるようにする。
    /// 正方形には、ビューアの下の説明で1行に収まらない長い代替テキストを付ける。細長には、画面の下端まで届く画像と説明の重なりを確かめるため、代替テキストを付ける。
    /// 横長には、説明にならない代替テキストを付ける。設定で無視していれば代替テキストのない画像に、無視しなければ付いた画像になる。
    private static let specs = [
        Spec(size: CGSize(width: 900, height: 1_600), color: .systemBlue, label: "1 縦長", description: "縦長の画像（9:16）"),
        Spec(size: CGSize(width: 1_600, height: 900), color: .systemGreen, label: "2 横長", description: "Screenshot"),
        Spec(
            size: CGSize(width: 1_200, height: 1_200),
            color: .systemOrange,
            label: "3 正方形",
            description: "正方形の画像。オレンジの地に白い格子が引かれ、中央に「3 正方形」と大きく書かれている。代替テキストが長いときに、ビューアの下の説明が1行で切れ、上へスワイプすると全文をシートで読めることを確かめるための文。"
        ),
        Spec(size: CGSize(width: 600, height: 2_000), color: .systemPurple, label: "4 細長", description: "画面の下端まで届く細長い画像"),
    ]

    /// 形の違う4枚。
    /// - Parameter idPrefix: 添付ファイルのIDの頭に付ける。投稿ごとに変え、ビューアが別の投稿のサムネイルへ戻らないようにする。
    static func attachments(idPrefix: String) -> [MediaAttachment] {
        attachments(specs, idPrefix: idPrefix)
    }

    /// 透明な部分と半透明な部分を持つ縦長の1枚。開閉で、透明な部分越しの見え方が途中で変わらないかを確かめる。
    static func singleTransparentAttachment(idPrefix: String) -> [MediaAttachment] {
        attachments([Spec(size: CGSize(width: 900, height: 1_600), color: .systemPink, label: "5 透過", description: "透明な部分のある画像", transparent: true)], idPrefix: idPrefix)
    }

    /// 縦長の1枚。1枚だけの投稿はサムネイルが一覧の幅いっぱいに大きく出るため、バーの下へ戻る開閉を確かめやすい。
    static func singleTallAttachment(idPrefix: String) -> [MediaAttachment] {
        attachments([specs[0]], idPrefix: idPrefix)
    }

    private static func attachments(_ specs: [Spec], idPrefix: String) -> [MediaAttachment] {
        specs.enumerated().compactMap { index, spec in
            guard let url = dataURL(for: spec) else { return nil }
            let size = MediaAttachment.Size(width: Int(spec.size.width), height: Int(spec.size.height))
            return MediaAttachment(
                id: "\(idPrefix)-\(index)",
                type: .image,
                url: url,
                previewUrl: url,
                description: spec.description,
                meta: MediaAttachment.Meta(original: size)
            )
        }
    }

    /// `spec`の画像をdata URLにする。透明な部分があればPNG、なければJPEGにする。
    private static func dataURL(for spec: Spec) -> URL? {
        let image = render(spec)
        if spec.transparent {
            guard let data = image.pngData() else { return nil }
            return URL(string: "data:image/png;base64,\(data.base64EncodedString())")
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        return URL(string: "data:image/jpeg;base64,\(data.base64EncodedString())")
    }

    /// 番号を描いた色違いの画像を、ペーストしたメディアとして渡す。添付の並びを見分けられるよう、1枚目から赤、青、オレンジ……の順にする。
    /// 添付から外すとファイルを置いたディレクトリごと消すので、1枚ずつ別のディレクトリに書く。
    static func pastedImages(count: Int) -> [PastedMedia] {
        let colors: [UIColor] = [.systemRed, .systemBlue, .systemOrange, .systemPurple, .systemGreen, .systemPink, .systemTeal, .systemYellow]
        return (0..<count).map { index in
            let image = DummyMedia.image(size: CGSize(width: 600, height: 600), color: colors[index % colors.count], label: "\(index + 1)")
            return PastedMedia(kind: .image) {
                let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appending(path: "dummy-\(index + 1).png")
                guard let data = image.pngData() else { throw LocalMediaError.loadFailed }
                try data.write(to: url)
                return LocalMediaFile(url: url, mimeType: "image/png", kind: .image)
            }
        }
    }

    /// 単色に格子と`label`を描いた画像。部品のカタログで、通信せずにサムネイルを出すために使う。
    static func image(size: CGSize, color: UIColor, label: String) -> UIImage {
        render(Spec(size: size, color: color, label: label, description: nil))
    }

    /// 単色に100pxの格子と番号を描く。格子で、拡大や切り抜きのずれを見分けられるようにする。`progress`を渡すと、再生していることが分かるよう、左から右へ動く白い帯を重ねる。
    private static func render(_ spec: Spec, progress: CGFloat? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !spec.transparent
        return UIGraphicsImageRenderer(size: spec.size, format: format).image { context in
            if spec.transparent {
                spec.color.withAlphaComponent(0.5).setFill()
                let side = min(spec.size.width, spec.size.height)
                context.cgContext.fillEllipse(in: CGRect(x: (spec.size.width - side) / 2, y: (spec.size.height - side) / 2, width: side, height: side))
            } else {
                spec.color.setFill()
                context.fill(CGRect(origin: .zero, size: spec.size))
            }
            let grid = UIBezierPath()
            for x in stride(from: 0, through: spec.size.width, by: 100) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: spec.size.height))
            }
            for y in stride(from: 0, through: spec.size.height, by: 100) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: spec.size.width, y: y))
            }
            grid.lineWidth = 2
            UIColor.white.setStroke()
            grid.stroke()
            if let progress {
                UIColor.white.withAlphaComponent(0.6).setFill()
                context.fill(CGRect(x: (spec.size.width - 60) * progress, y: 0, width: 60, height: spec.size.height))
            }
            let text = NSAttributedString(string: spec.label, attributes: [
                .font: UIFont.boldSystemFont(ofSize: min(spec.size.width, spec.size.height) / 4),
                .foregroundColor: UIColor.white,
            ])
            let textSize = text.size()
            text.draw(at: CGPoint(x: (spec.size.width - textSize.width) / 2, y: (spec.size.height - textSize.height) / 2))
        }
    }

    /// 横長の動画1本と縦長のGIF1本。GIFはMastodonと同じく、音のない動画として渡す。
    /// 動画には説明にならない代替テキストを付け、画像以外でも設定で無視されることを確かめられるようにする。
    /// GIFは、端末を縦にして撮った動画と同じく、横向きの画素に「90°回して表示する」回転情報を付けて書き出す。
    /// サムネイルは最初のコマ。書き出した動画は一時ディレクトリに残し、2回目からは書き出さない。
    static func videoAttachments() async throws -> (String) -> [MediaAttachment] {
        let video = Spec(size: CGSize(width: 1_280, height: 720), color: .systemTeal, label: "6 動画", description: "undefined")
        let gif = Spec(size: CGSize(width: 720, height: 1_280), color: .systemIndigo, label: "7 GIF", description: "縦長のGIF")
        let videoURL = try await movieURL(for: video, name: "dummy-video")
        let gifURL = try await movieURL(for: gif, name: "dummy-gif-rotated", rotated: true)
        let videoPreview = dataURL(for: video)
        let gifPreview = dataURL(for: gif)
        return { idPrefix in
            [
                MediaAttachment(
                    id: "\(idPrefix)-0",
                    type: .video,
                    url: videoURL,
                    previewUrl: videoPreview,
                    description: video.description,
                    meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: Int(video.size.width), height: Int(video.size.height)))
                ),
                MediaAttachment(
                    id: "\(idPrefix)-1",
                    type: .gifv,
                    url: gifURL,
                    previewUrl: gifPreview,
                    description: gif.description,
                    meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: Int(gif.size.width), height: Int(gif.size.height)))
                ),
            ]
        }
    }

    /// 90秒の横長の動画1本。毎秒の頭に短い音を鳴らし、10秒ごとに高い音にする。絵には経過した秒数を大きく描く。
    /// 再生の操作の部品で、シークバーや10秒戻る・進むで動かした位置と、消音を、絵と音の両方で確かめられるようにする。
    /// 書き出しに時間がかかるため、初回だけ書き出し、2回目からは一時ディレクトリに残したファイルを使う。
    static func longVideoAttachment() async throws -> (String) -> [MediaAttachment] {
        let spec = Spec(size: CGSize(width: 640, height: 360), color: .systemOrange, label: "8 長い動画", description: nil)
        let url = try await longMovieURL(for: spec, name: "dummy-long-video", seconds: 90)
        let preview = dataURL(for: spec)
        return { idPrefix in
            [
                MediaAttachment(
                    id: "\(idPrefix)-0",
                    type: .video,
                    url: url,
                    previewUrl: preview,
                    description: nil,
                    meta: MediaAttachment.Meta(original: MediaAttachment.Size(width: Int(spec.size.width), height: Int(spec.size.height)))
                ),
            ]
        }
    }

    /// 音のない動画と音声を別々に書き出し、1つのmp4にまとめる。
    private static func longMovieURL(for spec: Spec, name: String, seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mp4")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let silent = try await movieURL(for: spec, name: "\(name)-silent", frameCount: seconds * 10, framesPerSecond: 10) { time in
            String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
        }
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        try writeBeeps(to: audio, seconds: seconds)
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await combine(video: silent, audio: audio, to: partial)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: partial, to: url)
        }
        return url
    }

    /// 毎秒の頭に0.1秒の音を鳴らすAACを書き出す。10秒ごとの音は高くし、何秒目かを耳で数えやすくする。
    private static func writeBeeps(to url: URL, seconds: Int) throws {
        let sampleRate = 44_100.0
        let file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(sampleRate)
        for second in 0..<seconds {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                  let samples = buffer.floatChannelData?[0]
            else { throw DummyMediaError.writeFailed }
            buffer.frameLength = frames
            let frequency = second % 10 == 0 ? 880.0 : 440.0
            let beepFrames = Int(sampleRate * 0.1)
            for index in 0..<Int(frames) {
                samples[index] = index < beepFrames ? Float(0.3 * sin(2 * .pi * frequency * Double(index) / sampleRate)) : 0
            }
            try file.write(from: buffer)
        }
    }

    /// 動画と音声のトラックを、再エンコードせずに1つのmp4にまとめる。
    private static func combine(video: URL, audio: URL, to output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let composition = AVMutableComposition()
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw DummyMediaError.writeFailed }
        let duration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        try videoOut.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try audioOut.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)), of: audioTrack, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw DummyMediaError.writeFailed }
        try await export.export(to: output, as: .mp4)
    }

    /// `spec`の絵に白い帯が流れるmp4を書き出す。既定では30コマで2秒。
    /// 途中で失敗したファイルを次に使わないよう、別の名前で書き出してから置き換える。
    /// - Parameters:
    ///   - rotated: 画素を左へ90°回して書き、表示では右へ90°回す回転情報を付ける。
    ///   - labelAt: 秒数を受け取り、そのコマに描く文字を返す。nilなら`spec`の文字を描く。
    private static func movieURL(
        for spec: Spec,
        name: String,
        rotated: Bool = false,
        frameCount: Int = 60,
        framesPerSecond: Int32 = 30,
        labelAt: ((Double) -> String)? = nil
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mp4")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        let encodedSize = rotated ? CGSize(width: spec.size.height, height: spec.size.width) : spec.size
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(encodedSize.width),
            AVVideoHeightKey: Int(encodedSize.height),
        ])
        if rotated {
            input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(encodedSize.width),
            kCVPixelBufferHeightKey as String: Int(encodedSize.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? DummyMediaError.writeFailed }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                // 書き出しが失敗すると、受け付けられる状態に戻らない。
                guard writer.status == .writing else { throw writer.error ?? DummyMediaError.writeFailed }
                try await Task.sleep(for: .milliseconds(5))
            }
            var frameSpec = spec
            if let labelAt {
                frameSpec = Spec(size: spec.size, color: spec.color, label: labelAt(Double(frame) / Double(framesPerSecond)), description: spec.description)
            }
            let image = render(frameSpec, progress: CGFloat(frame) / CGFloat(frameCount - 1))
            guard let buffer = pixelBuffer(of: image, in: adaptor, rotated: rotated),
                  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond))
            else { throw writer.error ?? DummyMediaError.writeFailed }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? DummyMediaError.writeFailed }
        // 同時に書き出した別の要求が先に置いていれば、そちらを使う。
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: partial, to: url)
        }
        return url
    }

    private static func pixelBuffer(of image: UIImage, in adaptor: AVAssetWriterInputPixelBufferAdaptor, rotated: Bool) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool, let cgImage = image.cgImage else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        if rotated {
            // 左へ90°回して描く。CGContextは上向きのy軸なので、正の角度が左回りになる。
            context.translateBy(x: CGFloat(CVPixelBufferGetWidth(buffer)), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(cgImage, in: CGRect(origin: .zero, size: CGSize(width: cgImage.width, height: cgImage.height)))
        return buffer
    }

    private enum DummyMediaError: Error {
        case writeFailed
    }
}
#endif
