import SciaCore
import UIKit

/// 画像を枠いっぱいに、縦横比を保って切り抜いて描く。投稿者が焦点を付けていれば、焦点がなるべく枠の中央に来るように切り抜く。
/// `UIImageView`の`scaleAspectFill`は中央でしか切り抜けないため、中に画像を置き、枠より大きく広げてずらす。
/// 枠をUIKitのアニメーションで動かすときは、同じアニメーションの中で`layoutIfNeeded`を呼び、中の画像も一緒に動かす。
/// 呼ばないと、中の画像だけが動き終えた位置へ飛ぶ。毎フレーム枠を置き直す動きでは、描く前に並べ直されるため呼ばなくてよい。
final class FocusCroppedImageView: UIView {
    private let imageView = UIImageView()

    var image: UIImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            setNeedsLayout()
        }
    }

    var focus: MediaFocus? {
        didSet {
            if focus != oldValue { setNeedsLayout() }
        }
    }

    /// 縁に描く白いフチの幅。画像はフチの内側に収める。一覧で重ねた写真の紙を、ビューアの開閉の複製でも描くのに使う。
    /// フチはレイヤーの縁取りで、画像より手前に描かれるので、内側からはみ出た画像の端はフチに隠れる。
    var paperBorder: CGFloat = 0 {
        didSet {
            guard paperBorder != oldValue else { return }
            layer.borderWidth = paperBorder
            // 色は消さない。太さだけをアニメーションで細くしている間も、白いまま見せるため。太さが0なら描かれない。
            if paperBorder > 0 {
                layer.borderColor = UIColor.white.cgColor
            }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        // 置き換える前の`UIImageView`と同じく、触れたものを奥へ通す。ビューアの複製は開く途中もページより手前にあり、受けるとページを切り替えられなくなる。
        isUserInteractionEnabled = false
        // 届いた画像の縦横比が添付ファイルの大きさと違っても、枠に画像のない部分を作らない。
        imageView.contentMode = .scaleAspectFill
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.insetBy(dx: paperBorder, dy: paperBorder)
        imageView.frame = MediaFocus.fillFrame(imageSize: imageView.image?.size ?? inner.size, in: inner, focus: focus)
    }
}
