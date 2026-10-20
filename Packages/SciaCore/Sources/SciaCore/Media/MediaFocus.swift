public import CoreGraphics

/// 投稿者が添付ファイルに付けた焦点。サムネイルで切り抜いても見せたい点。
/// 画像の中央を0にして、xは左端の-1から右端の1へ、yは下端の-1から上端の1へ増える。
/// https://docs.joinmastodon.org/api/guidelines/#focal-points
public struct MediaFocus: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// 画像を枠いっぱいに縦横比を保って敷いたときの、画像の枠。はみ出した部分は切り抜く前提。
    /// 焦点がなるべく枠の中央に来るようにずらし、枠の中に画像のない部分ができる手前で止める。焦点がなければ中央で切り抜く。
    /// Mastodonのwebは、焦点を割合にしたCSSの`object-position`で切り抜くため、焦点が枠の中央より端寄りに残る。
    /// 投稿者が選んだ点を見せることを優先し、中央へ寄せる。
    public static func fillFrame(imageSize: CGSize, in bounds: CGRect, focus: MediaFocus?) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        // 画像の左上を0、右下を1にした焦点の位置。
        let point = (x: ((focus?.x).map(clamped) ?? 0) / 2 + 0.5, y: 0.5 - ((focus?.y).map(clamped) ?? 0) / 2)
        let x = min(max(bounds.width / 2 - size.width * point.x, bounds.width - size.width), 0)
        let y = min(max(bounds.height / 2 - size.height * point.y, bounds.height - size.height), 0)
        return CGRect(x: bounds.minX + x, y: bounds.minY + y, width: size.width, height: size.height)
    }

    /// `fillFrame`で枠に見えている部分を、画像の左上を0、右下を1にした割合で表す。レイヤーの`contentsRect`に使う。
    public static func contentsRect(imageSize: CGSize, boundsSize: CGSize, focus: MediaFocus?) -> CGRect {
        let frame = fillFrame(imageSize: imageSize, in: CGRect(origin: .zero, size: boundsSize), focus: focus)
        guard frame.width > 0, frame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(
            x: -frame.minX / frame.width,
            y: -frame.minY / frame.height,
            width: boundsSize.width / frame.width,
            height: boundsSize.height / frame.height
        )
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }
}
