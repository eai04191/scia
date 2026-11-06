import SciaCore
import UIKit

/// ユーザーのアイコンを、メニューなどの記号の代わりに置く画像にする。
enum AvatarIcon {
    /// メニューのアイコンの一辺。本文の文字の大きさの設定に合わせる。
    static var menuSide: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 22)
    }

    /// アイコンを、一辺`side`の正方形でタイムラインと同じ形に切り抜き、元の色のまま描く。動くアイコンは先頭のコマで止める。
    static func image(_ avatar: UIImage, side: CGFloat, shape: AvatarShape) -> UIImage? {
        let image = avatar.images?.first ?? avatar
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let clip = path(in: bounds, shape: shape)
        let scale = max(side / image.size.width, side / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            clip.addClip()
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysOriginal)
    }

    /// タイムラインのアイコンと同じ形の輪郭。
    static func path(in bounds: CGRect, shape: AvatarShape) -> UIBezierPath {
        switch shape {
        case .roundedSquare: UIBezierPath(roundedRect: bounds, cornerRadius: bounds.width * 0.2)
        case .circle: UIBezierPath(ovalIn: bounds)
        }
    }
}
