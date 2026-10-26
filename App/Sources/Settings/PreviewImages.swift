import ImageIO
import os
import SciaCore
import UIKit
import UniformTypeIdentifiers

/// 設定の見本の投稿に出す画像。アプリのアイコンの絵から作る。
/// アイコンの絵（`AppIconPreview`）はホーム画面と同じ角丸で切り抜かれ、縁に光る線も入っているため、そのままでは見本のアイコンやカードの枠と角が合わない。
/// 見本のアイコンとカードは画像をURLから読むため、作った画像のPNGをメモリに持ち、このアプリだけのスキームのURLを渡す。
/// 画像のストアは、このURLを通信に送らずに`data(for:)`から読む。通信の層はhttpとhttps以外を送らないため（docs/network.md）、ファイルに書いて`file:`のURLを渡すと読めない。
/// どの画像も起動している間に1回だけ作る。
@MainActor
enum PreviewImages {
    private static var images: [URL: Data] = [:]
    private static var cachedAvatar: UIImage?
    private static let logger = SciaLog.logger(category: "settings")
    private static let scheme = "scia-preview"
    /// リンクカードの画像で、灰色の四角の幅に対するアイコンの幅。
    private static let cardIconRatio: CGFloat = 0.8
    /// 見本のアイコンで、アイコンの絵を拡大する倍率。角丸の外の透明な部分と縁の線を、見本のアイコンの形の外へ出す。
    private static let avatarZoom: CGFloat = 1.1
    /// 動くアイコンの1辺のピクセル数。見本のアイコンと絵文字を、拡大せずに描ける大きさにする。
    private static let animatedSide: CGFloat = 192
    /// 動くアイコンのコマの数と、1コマの長さ。色相を1周させる。
    private static let animatedFrameCount = 16
    private static let animatedFrameDuration: TimeInterval = 0.1
    /// アプリのアイコンの青の色相。
    private static let animatedBaseHue: CGFloat = 0.58

    /// 見本の投稿者のアイコン。アイコンの絵を拡大して、見本のアイコンの形だけで角を切り抜かせる。作れなければnil。
    static func avatarURL() -> URL? {
        image(named: "avatar") { avatar() }
    }

    /// 見本の投稿者のアイコンと絵文字の、アニメーション版。静止画（`avatarURL()`）を最初のコマにして、色を1周させるGIF。
    /// アニメーションを再生する設定の違いが、プレビューで見て分かるようにする。作れなければnil。
    /// 色はCore Imageの色相の回転ではなく、Core Graphicsの色相の合成で塗る。Core Imageでは準備と描画に、シミュレーターで130msほどメインスレッドが止まるため。
    static func animatedAvatarURL() -> URL? {
        data(named: "avatar-animated") {
            guard let original = avatar() else { return nil }
            let bounds = CGRect(x: 0, y: 0, width: animatedSide, height: animatedSide)
            // 元の大きな画像をコマごとに縮めて描くと遅いため、先に1回だけ縮める。
            let still = renderer(size: bounds.size, scale: 1).image { _ in original.draw(in: bounds) }
            let frames = (0..<animatedFrameCount).compactMap { index -> CGImage? in
                renderer(size: bounds.size, scale: 1).image { context in
                    still.draw(in: bounds)
                    guard index > 0 else { return }
                    // アイコンの青から色相を回す。白い線は彩度がないので、白のまま残る。
                    let hue = (animatedBaseHue + CGFloat(index) / CGFloat(animatedFrameCount)).truncatingRemainder(dividingBy: 1)
                    UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
                    context.fill(bounds, blendMode: .hue)
                    // 色を塗った分の透明な部分を、アイコンの形に切り抜き直す。
                    still.draw(in: bounds, blendMode: .destinationIn, alpha: 1)
                }.cgImage
            }
            guard frames.count == animatedFrameCount else {
                logger.error("preview animated avatar render failed")
                return nil
            }
            return gif(frames)
        }
    }

    /// 見本の投稿者のアイコンの静止画。アイコンの絵を拡大して、見本のアイコンの形だけで角を切り抜かせる。
    private static func avatar() -> UIImage? {
        if let cachedAvatar { return cachedAvatar }
        guard let icon = appIcon() else { return nil }
        let size = icon.size
        let image = renderer(size: size, scale: icon.scale).image { _ in
            let side = size.width * avatarZoom
            icon.draw(in: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side))
        }
        cachedAvatar = image
        return image
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

    /// 見本の画像のURLなら、そのPNG。ほかのURLならnil。
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

    private static func gif(_ frames: [CGImage]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.gif.identifier as CFString, frames.count, nil) else {
            logger.error("preview animated avatar encode failed")
            return nil
        }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: animatedFrameDuration]]
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, delay as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            logger.error("preview animated avatar encode failed")
            return nil
        }
        return data as Data
    }
}
