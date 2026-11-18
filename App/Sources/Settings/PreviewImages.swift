import AVFoundation
import ImageIO
import os
import SciaCore
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

/// 設定の見本の投稿に出す画像。アプリのアイコンの絵から作る。
/// 見本のアイコンと絵文字には、ビルドで書き出した角まで絵の詰まった四角の絵と、その軌跡がうねる動画（Tools/render-preview-avatar.py）を使う。
/// ホーム画面と同じ角丸で切り抜かれたアイコンの絵（`AppIconPreview`）では、アイコンの形と角丸の丸みの設定で切り抜いたときに、角に透明な部分と縁の線が残るため。
/// 見本のアイコンとカードは画像をURLから読むため、画像のPNGをメモリに持ち、このアプリだけのスキームのURLを渡す。
/// 画像のストアは、このURLを通信に送らずに`data(for:)`から読む。通信の層はhttpとhttps以外を送らないため（docs/network.md）、ファイルに書いて`file:`のURLを渡すと読めない。
/// どの画像も起動している間に1回だけ読むか作る。
@MainActor
enum PreviewImages {
    private static var images: [URL: Data] = [:]
    private static let logger = SciaLog.logger(category: "settings")
    private static let scheme = "scia-preview"
    /// リンクカードの画像で、灰色の四角の幅に対するアイコンの幅。
    private static let cardIconRatio: CGFloat = 0.8
    private static let animatedAvatarName = "avatar-animated"
    private static var animatedAvatarRender: Task<URL?, Never>?

    /// 見本の投稿者のアイコン。角まで絵の詰まった四角の絵で、見本のアイコンの形だけで角を切り抜かせる。読めなければnil。
    static func avatarURL() -> URL? {
        data(named: "avatar") {
            guard let url = Bundle.main.url(forResource: "AppIconSquarePreview", withExtension: "png"), let data = try? Data(contentsOf: url) else {
                logger.error("preview square app icon missing")
                return nil
            }
            return data
        }
    }

    /// 見本の投稿者のアイコンと絵文字の、アニメーション版（`AnimatedPreviewAvatar`）。作り終えていなければ、作り始めてnilを返す。
    /// 作り終えるまでは、見本に静止画を出しておく。SE3では作るのに0.4秒ほどかかり、その間アニメーション版のURLを渡すと、アイコンと絵文字が灰色や空白のままになるため。
    static func animatedAvatarURL() -> URL? {
        guard let url = URL(string: "\(scheme)://\(animatedAvatarName)") else { return nil }
        if images[url] != nil { return url }
        startAnimatedAvatarRender()
        return nil
    }

    /// アニメーション版を作り終えるのを待って、そのURLを返す。作れなければnil。
    static func animatedAvatarWhenReady() async -> URL? {
        startAnimatedAvatarRender()
        return await animatedAvatarRender?.value
    }

    private static func startAnimatedAvatarRender() {
        guard animatedAvatarRender == nil, let url = URL(string: "\(scheme)://\(animatedAvatarName)") else { return }
        guard let video = Bundle.main.url(forResource: "AppIconSquarePreviewAnimated", withExtension: "mp4") else {
            logger.error("preview animated avatar video missing")
            return
        }
        animatedAvatarRender = Task(.withoutRequests) {
            guard let data = await AnimatedPreviewAvatar.render(from: video) else { return nil }
            images[url] = data
            return url
        }
    }

    /// リンクカードの画像。灰色の四角の中央に、アイコンを小さく置く。灰色は外観に合わせる。作れなければnil。
    static func cardURL(for style: UIUserInterfaceStyle) -> URL? {
        image(named: "card-\(style == .dark ? "dark" : "light")") {
            guard let icon = appIcon() else { return nil }
            let side = icon.size.width / cardIconRatio
            return renderer(size: CGSize(width: side, height: side), scale: icon.scale).image { context in
                // ダークのsystemGray5はカードの地とほぼ同じ色で、灰色の四角が見えなくなるため、1段明るくする。
                let gray: UIColor = style == .dark ? .systemGray4 : .systemGray5
                gray.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                let inset = (side - icon.size.width) / 2
                icon.draw(in: CGRect(x: inset, y: inset, width: icon.size.width, height: icon.size.height))
            }
        }
    }

    /// 見本の投稿に添付する写真のURL。アプリに同梱した写真を読む。読めなければnil。
    static func photoURL(_ photo: PreviewPhoto) -> URL? {
        data(named: photo.rawValue) {
            guard let url = Bundle.main.url(forResource: photo.rawValue, withExtension: "avif"), let data = try? Data(contentsOf: url) else {
                logger.error("preview photo missing name=\(photo.rawValue, privacy: .public)")
                return nil
            }
            return data
        }
    }

    /// 見本の投稿（`AppearancePreviewSamples`）に渡す画像の場所。
    static func sampleSources() -> PreviewSampleSources {
        PreviewSampleSources(
            avatar: avatarURL(),
            animatedAvatar: animatedAvatarURL(),
            darkCard: cardURL(for: .dark),
            lightCard: cardURL(for: .light),
            photos: photoURLs(PreviewPhoto.allCases),
            linkCardURL: AppInfo.repository
        )
    }

    /// 見本の通知（`NotificationAppearancePreviewSamples`）に渡す画像の場所。通知の見本が使うアイコンと写真だけを用意し、動くアイコンとリンクカードの画像は作らない。
    static func notificationSampleSources() -> PreviewSampleSources {
        PreviewSampleSources(avatar: avatarURL(), animatedAvatar: nil, darkCard: nil, lightCard: nil, photos: photoURLs(NotificationAppearancePreviewSamples.photos), linkCardURL: nil)
    }

    private static func photoURLs(_ photos: [PreviewPhoto]) -> [PreviewPhoto: URL] {
        var urls: [PreviewPhoto: URL] = [:]
        for photo in photos {
            urls[photo] = photoURL(photo)
        }
        return urls
    }

    /// 見本の画像のURLなら、その画像のデータ。ほかのURLならnil。
    static func data(for url: URL) -> Data? {
        url.scheme == scheme ? images[url] : nil
    }

    private static func image(named name: String, make: () -> UIImage?) -> URL? {
        data(named: name) {
            guard let image = make() else { return nil }
            guard let data = image.pngData() else {
                logger.error("preview image encode failed name=\(name, privacy: .public)")
                return nil
            }
            return data
        }
    }

    private static func data(named name: String, make: () -> Data?) -> URL? {
        guard let url = URL(string: "\(scheme)://\(name)") else { return nil }
        if images[url] != nil { return url }
        guard let data = make() else { return nil }
        images[url] = data
        return url
    }

    private static func appIcon() -> UIImage? {
        guard let icon = UIImage(named: "AppIconPreview") else {
            logger.error("preview app icon missing")
            return nil
        }
        return icon
    }

    private static func renderer(size: CGSize, scale: CGFloat) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format)
    }
}

/// 見本の投稿者のアイコンと絵文字の、アニメーション版。アプリに入れた動画（Tools/render-preview-avatar.py）をコマに展開し、APNGにまとめる。
/// 見本の画像は、タイムラインのアイコンと絵文字と同じ画像のストアで描くため、動く画像のデータにする必要がある。APNGのままアプリに入れると約4MBになるので、動画で入れる。
/// SE3では展開に0.04秒、APNGにまとめるのに0.36秒ほどかかるため、メインスレッドの外で作る。
enum AnimatedPreviewAvatar {
    private static let logger = SciaLog.logger(category: "settings")

    @concurrent
    static func render(from video: URL) async -> Data? {
        do {
            return try apng(await frames(of: video))
        } catch {
            logger.error("preview animated avatar render failed error=\(SciaLog.describe(error), privacy: .public)")
            return nil
        }
    }

    /// 動画のコマと、そのコマを見せる長さ。長さは、次のコマの表示時刻までで、最後のコマは動画の終わりまで。
    private static func frames(of url: URL) async throws -> [(image: CGImage, duration: CMTime)] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let end = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var images: [(image: CGImage, time: CMTime)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            guard let image else { throw CocoaError(.fileReadCorruptFile) }
            images.append((image, CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        guard reader.status == .completed, !images.isEmpty else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return images.indices.map { index in
            let next = index + 1 < images.count ? images[index + 1].time : end
            return (images[index].image, next - images[index].time)
        }
    }

    private static func apng(_ frames: [(image: CGImage, duration: CMTime)]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, frames.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let loop = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        for frame in frames {
            let delay = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: frame.duration.seconds]]
            CGImageDestinationAddImage(destination, frame.image, delay as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}
