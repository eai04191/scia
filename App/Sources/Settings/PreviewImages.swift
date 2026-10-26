import os
import SciaCore
import UIKit

/// 設定の見本の投稿に出す画像。アプリのアイコンの絵から作る。
/// アイコンの絵（`AppIconPreview`）はホーム画面と同じ角丸で切り抜かれ、縁に光る線も入っているため、そのままでは見本のアイコンやカードの枠と角が合わない。
/// 見本のアイコンとカードは画像をURLから読むため、作った画像のPNGをメモリに持ち、このアプリだけのスキームのURLを渡す。
/// 画像のストアは、このURLを通信に送らずに`data(for:)`から読む。通信の層はhttpとhttps以外を送らないため（docs/network.md）、ファイルに書いて`file:`のURLを渡すと読めない。
/// どの画像も起動している間に1回だけ作る。
@MainActor
enum PreviewImages {
    private static var images: [URL: Data] = [:]
    private static let logger = SciaLog.logger(category: "settings")
    private static let scheme = "scia-preview"
    /// リンクカードの画像で、灰色の四角の幅に対するアイコンの幅。
    private static let cardIconRatio: CGFloat = 0.8
    /// 見本のアイコンで、アイコンの絵を拡大する倍率。角丸の外の透明な部分と縁の線を、見本のアイコンの形の外へ出す。
    private static let avatarZoom: CGFloat = 1.1

    /// 見本の投稿者のアイコン。アイコンの絵を拡大して、見本のアイコンの形だけで角を切り抜かせる。作れなければnil。
    static func avatarURL() -> URL? {
        image(named: "avatar") {
            guard let icon = appIcon() else { return nil }
            let size = icon.size
            return renderer(size: size, scale: icon.scale).image { _ in
                let side = size.width * avatarZoom
                icon.draw(in: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side))
            }
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

    /// 見本の画像のURLなら、そのPNG。ほかのURLならnil。
    static func data(for url: URL) -> Data? {
        url.scheme == scheme ? images[url] : nil
    }

    private static func image(named name: String, make: () -> UIImage?) -> URL? {
        guard let url = URL(string: "\(scheme)://\(name)") else { return nil }
        if images[url] != nil { return url }
        guard let image = make() else { return nil }
        guard let data = image.pngData() else {
            logger.error("preview image encode failed name=\(name, privacy: .public)")
            return nil
        }
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
