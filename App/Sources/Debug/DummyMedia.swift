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
            description: "正方形の画像。オレンジの地に白い格子が引かれ、中央に「3 正方形」と大きく書かれている。代替テキストが長いときに、ビューアの下の説明が1行で切れ、上へ払うと全文をシートで読めることを確かめるための文。"
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

    /// `spec`の絵に白い帯が流れる2秒のmp4を書き出す。
    /// 途中で失敗したファイルを次に使わないよう、別の名前で書き出してから置き換える。
    /// - Parameter rotated: 画素を左へ90°回して書き、表示では右へ90°回す回転情報を付ける。
    private static func movieURL(for spec: Spec, name: String, rotated: Bool = false) async throws -> URL {
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
        let frameCount = 60
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                // 書き出しが失敗すると、受け付けられる状態に戻らない。
                guard writer.status == .writing else { throw writer.error ?? DummyMediaError.writeFailed }
                try await Task.sleep(for: .milliseconds(5))
            }
            let image = render(spec, progress: CGFloat(frame) / CGFloat(frameCount - 1))
            guard let buffer = pixelBuffer(of: image, in: adaptor, rotated: rotated),
                  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
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
