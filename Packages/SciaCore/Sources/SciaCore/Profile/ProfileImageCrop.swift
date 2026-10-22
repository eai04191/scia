public import CoreGraphics

/// アイコンとヘッダー画像を切り抜く枠。
///
/// 切り抜く画面では、枠と同じ大きさのスクロールビューに画像を載せ、拡大と移動で枠に入れる部分を選ぶ。ここでは、その位置から画像の中の範囲を求める。
public struct ProfileImageCrop: Sendable, Equatable {
    /// 枠の縦横比（幅÷高さ）。
    public let aspect: Double
    /// 送る画像の画素数の上限。
    public let maxPixelCount: Double

    /// Mastodonはアイコンを400×400に中央で切り抜いて縮めるので、正方形に切り抜き、400×400より大きくは送らない。
    public static let avatar = ProfileImageCrop(aspect: 1, maxPixelCount: 400 * 400)

    /// ヘッダー画像の比率。Mastodonはヘッダー画像を切り抜かず、比率はクライアントが決める。
    public enum HeaderAspect: CaseIterable, Sendable {
        /// 3:2。Sciaが勧める比率で、切り抜くときの既定。多くのアプリが3:2に近い枠で見せ、3:1より綺麗に見せられるため。
        case standard
        /// 3:1。Mastodonのweb版の編集画面（4.6.0から）が切り抜く比率。
        case wide

        /// 幅÷高さ。
        public var ratio: Double {
            switch self {
            case .standard: 3.0 / 2
            case .wide: 3
            }
        }
    }

    /// Mastodonはヘッダー画像を、1500×500と同じ画素数に収まるまで、比率を保って縮めて保存する。
    public static func header(_ aspect: HeaderAspect) -> ProfileImageCrop {
        ProfileImageCrop(aspect: aspect.ratio, maxPixelCount: 1500 * 500)
    }

    /// 画像が枠を埋める最小の倍率。これより縮めると、枠に画像のない部分ができる。
    public static func minimumZoomScale(imageSize: CGSize, frameSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return max(frameSize.width / imageSize.width, frameSize.height / imageSize.height)
    }

    /// 枠に見えている、画像の中の範囲（ピクセル）。縦横比は枠に合わせ、画像からはみ出さないよう収める。
    /// - Parameters:
    ///   - imageSize: 画像の大きさ（ピクセル）。
    ///   - frameSize: 枠の大きさ（ポイント）。
    ///   - contentOffset: スクロールビューの位置。画像の左上を原点とする。
    ///   - zoomScale: 画像の1ピクセルを何ポイントで見せているか。
    public func cropRect(imageSize: CGSize, frameSize: CGSize, contentOffset: CGPoint, zoomScale: CGFloat) -> CGRect {
        guard zoomScale > 0, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        // 枠の幅から幅を決め、高さは縦横比で決める。丸めた分で縦横比がずれないよう、幅を先に整数にする。
        var width = (frameSize.width / zoomScale).rounded()
        var height = (width / aspect).rounded()
        // 画像より大きくならないよう、縦横比を保って縮める。
        if width > imageSize.width {
            width = imageSize.width.rounded(.down)
            height = (width / aspect).rounded()
        }
        if height > imageSize.height {
            height = imageSize.height.rounded(.down)
            width = (height * aspect).rounded()
        }
        let x = min(max((contentOffset.x / zoomScale).rounded(), 0), imageSize.width - width)
        let y = min(max((contentOffset.y / zoomScale).rounded(), 0), imageSize.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 切り抜いた範囲を送る大きさ。画素数が上限より多ければ縦横比を保って縮め、少なければそのまま送る。
    public func outputSize(for cropSize: CGSize) -> CGSize {
        guard cropSize.width > 0, cropSize.height > 0 else { return .zero }
        let scale = min(1, (maxPixelCount / (cropSize.width * cropSize.height)).squareRoot())
        var width = (cropSize.width * scale).rounded()
        var height = (cropSize.height * scale).rounded()
        // 丸めて上限を超えたら、上限に収まるまで幅を1ずつ減らす。
        while width * height > maxPixelCount, width > 1 {
            width -= 1
            height = (width / aspect).rounded()
        }
        return CGSize(width: width, height: height)
    }
}
