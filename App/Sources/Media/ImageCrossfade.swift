import UIKit

/// 前の画像を薄くして消すために、画像ビューに重ねた像。
private final class FadingImageCopy: UIImageView {}

extension UIImageView {
    /// いま出している画像の像を手前に重ね、`duration`秒かけて薄くして消す。続けて画像を差し替えると、前の画像から薄く入れ替わって見える。
    /// 像は自身いっぱいに広げて大きさに付いていかせるので、差し替えで枠の大きさや拡大の変形が変わっても、同じ位置に重なる。
    /// 縦横比の違う画像へ差し替えると像が伸びるため、同じ添付ファイルのぼかしから元の画像へのように、縦横比のそろったものに使う。
    /// `duration`が0なら、1コマで差し替えるものとして、薄くしている途中の像を外す。残すと、別の画像の手前に前の画像が重なって見える。
    /// - Parameter startAlpha: 像の濃さの始まり。薄くしている途中の見え方を、別の画像ビューへ引き継ぐときに渡す。
    func fadeOutCurrentImage(duration: TimeInterval, from startAlpha: CGFloat = 1) {
        guard duration > 0 else {
            for copy in subviews where copy is FadingImageCopy {
                copy.removeFromSuperview()
            }
            return
        }
        guard let image else { return }
        let copy = FadingImageCopy(image: image)
        copy.contentMode = contentMode
        copy.frame = bounds
        copy.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        copy.isUserInteractionEnabled = false
        copy.alpha = startAlpha
        addSubview(copy)
        UIView.animateSmoothly(duration: duration) {
            copy.alpha = 0
        } completion: {
            copy.removeFromSuperview()
        }
    }

    /// 薄くしている途中の前の画像と、いま見えている濃さ。薄くしていなければnil。
    var fadingImage: (image: UIImage, alpha: CGFloat)? {
        guard let copy = subviews.last(where: { $0 is FadingImageCopy }) as? UIImageView, let image = copy.image else { return nil }
        let alpha = CGFloat(copy.layer.presentation()?.opacity ?? Float(copy.alpha))
        return alpha > 0 ? (image, alpha) : nil
    }
}
