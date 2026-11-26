import SciaCore
import UIKit

/// 画像を枠いっぱいに、縦横比を保って切り抜いて描く。投稿者が焦点を付けていれば、焦点がなるべく枠の中央に来るように切り抜く。
/// `UIImageView`の`scaleAspectFill`は中央でしか切り抜けないため、中に画像を置き、枠より大きく広げてずらす。
/// 枠をUIKitのアニメーションで動かすときは、同じアニメーションの中で`layoutIfNeeded`を呼び、中の画像も一緒に動かす。
/// 呼ばないと、中の画像だけが動き終えた位置へ飛ぶ。毎フレーム枠を置き直す動きでは、描く前に並べ直されるため呼ばなくてよい。
final class FocusCroppedImageView: UIView {
    private let imageView = DynamicRangeFollowingImageView()
    /// `imageView`と同じ画像を、ほかの明るさの幅で描いて重ねる。開閉の複製で、ビューアと一覧の明るさのあいだを移すのに使う。
    private let blendView = DynamicRangeFollowingImageView()
    /// 中の画像を薄くしたぶん見せる、紙の白。
    private let paperView = UIView()
    /// 全体を暗くする。
    private let dimView = UIView()

    /// 中の画像の不透明度。下げたぶん、紙の白を見せる。タイムラインで中身を描かずに紙だけを見せる写真へ、ビューアの複製を着かせるときに使う。
    var contentOpacity: CGFloat = 1 {
        didSet {
            applyOpacities()
            paperView.alpha = 1 - contentOpacity
        }
    }

    /// 重ねて描く明るさの幅。nilなら重ねず、まわりの明るさだけで描く。
    private(set) var blendedDynamicRange: UIImage.DynamicRange?
    /// 重ねた明るさの画像の不透明度。1なら重ねた明るさだけで描く。
    private(set) var dynamicRangeBlend: CGFloat = 0

    /// 中の画像を、まわりの明るさの代わりに`range`で描いた画像を`amount`の不透明度で重ねて描く。`range`がnilなら重ねない。
    /// 明るさの幅は3段で、途中の値を指定できないため、2つの明るさの画像の不透明度を入れ替えて移す。
    func blendDynamicRange(_ range: UIImage.DynamicRange?, amount: CGFloat) {
        blendedDynamicRange = range
        dynamicRangeBlend = range == nil ? 0 : min(max(amount, 0), 1)
        if let range, !blendView.traitOverrides.contains(MediaDynamicRangeTrait.self) || blendView.traitOverrides.mediaDynamicRange != range {
            blendView.traitOverrides.mediaDynamicRange = range
        }
        applyOpacities()
    }

    /// `source`の明るさで描いた画像を`amount`の不透明度で重ねる。`source`が自分と同じ明るさなら重ねない。
    func blendDynamicRange(toward source: UIView, amount: CGFloat) {
        let range = source.traitCollection.mediaDynamicRange
        blendDynamicRange(range == traitCollection.mediaDynamicRange ? nil : range, amount: amount)
    }

    /// 入れ替えの終わりに、下の画像を薄くしてなくす区間。入れ替えの進み具合の幅。
    var dynamicRangeUnderFadePortion: CGFloat = 0.1 {
        didSet { applyOpacities() }
    }

    /// 下の画像は、重ねた画像が不透明に近づく終わりの区間で薄くしてなくす。不透明な画像は、重ねた画像の下に下の画像が不透明なまま残らないと透けて見えるので、区間の外では薄くしない。
    /// 下の画像を最後まで残すと、透明な部分のある画像が2枚重なった不透明度のまま着き、複製を外したところで薄くなる。
    private func applyOpacities() {
        blendView.alpha = contentOpacity * dynamicRangeBlend
        let portion = max(dynamicRangeUnderFadePortion, 0.01)
        imageView.alpha = contentOpacity * min(max((1 - dynamicRangeBlend) / portion, 0), 1)
    }

    /// アニメーションで動かしている途中の、見えている重ねた画像の不透明度。
    var presentedDynamicRangeBlend: CGFloat {
        let content = 1 - CGFloat(paperView.layer.presentation()?.opacity ?? Float(paperView.alpha))
        guard content > 0 else { return dynamicRangeBlend }
        return min(max(CGFloat(blendView.layer.presentation()?.opacity ?? Float(blendView.alpha)) / content, 0), 1)
    }

    /// 見えている画像の明るさの幅と、不透明な画像でその明るさが見えている割合。下の画像は、重ねた画像に覆われた分を除く。
    /// 開閉の両端で、複製がどの明るさで描いているかを確かめるのに使う。
    var visibleDynamicRanges: [(range: UIImage.DynamicRange, alpha: CGFloat)] {
        [
            (imageView.preferredImageDynamicRange, imageView.alpha * (1 - blendView.alpha)),
            (blendView.preferredImageDynamicRange, blendView.alpha),
        ].filter { $0.1 > 0 }
    }

    /// 全体を暗くする度合い。タイムラインで暗くした写真へ、ビューアの複製を着かせるときに使う。
    var dimming: CGFloat = 0 {
        didSet { dimView.alpha = dimming }
    }

    var image: UIImage? {
        get { imageView.image }
        set { setImage(newValue, crossfadeDuration: 0) }
    }

    /// 最後に画像を差し替えたときに、前の画像から薄く入れ替えた時間。0なら1コマで差し替えた。
    /// 同じ見た目の複製（ビューアの開閉でタイムラインの中に置く複製）を、同じ入れ替え方でそろえるのに使う。
    private(set) var lastCrossfadeDuration: TimeInterval = 0

    /// 画像を差し替える。`crossfadeDuration`が0より大きければ、前の画像をその時間で薄くして入れ替える。
    /// - Parameter startAlpha: 前の画像の不透明度の始まり。ほかで薄くしている途中の見え方を引き継ぐときに渡す。
    func setImage(_ newImage: UIImage?, crossfadeDuration: TimeInterval, from startAlpha: CGFloat = 1) {
        lastCrossfadeDuration = crossfadeDuration
        if newImage !== imageView.image {
            imageView.fadeOutCurrentImage(duration: crossfadeDuration, from: startAlpha)
            blendView.fadeOutCurrentImage(duration: crossfadeDuration, from: startAlpha)
        }
        imageView.image = newImage
        blendView.image = newImage
        setNeedsLayout()
    }

    var focus: MediaFocus? {
        didSet {
            if focus != oldValue { setNeedsLayout() }
        }
    }

    /// 縁に描く白いフチの幅。画像はフチの内側に収める。タイムラインで重ねた写真の紙を、ビューアの開閉の複製でも描くのに使う。
    /// フチはレイヤーの縁取りで、画像より手前に描かれるので、内側からはみ出た画像の端はフチに隠れる。
    var paperBorder: CGFloat = 0 {
        didSet {
            guard paperBorder != oldValue else { return }
            layer.borderWidth = paperBorder
            // 色は消さない。太さだけをアニメーションで細くしている間も、白いまま見せるため。太さが0なら描かれない。
            if paperBorder > 0 {
                layer.borderColor = paperColor.cgColor
            }
            setNeedsLayout()
        }
    }

    /// 紙（フチと、中身を薄くしたぶん見せる下地）の色。ビューアは画面を常にダークにしているので、自分の外観では決めず、
    /// 使う側が起点の写真の外観で解決した色を渡す。
    var paperColor: UIColor = .white {
        didSet {
            paperView.backgroundColor = paperColor
            layer.borderColor = paperBorder > 0 ? paperColor.cgColor : layer.borderColor
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        // 置き換える前の`UIImageView`と同じく、触れたものを奥へ通す。ビューアの複製は開く途中もページより手前にあり、受けるとページを切り替えられなくなる。
        isUserInteractionEnabled = false
        // 届いた画像の縦横比が添付ファイルの大きさと違っても、枠に画像のない部分を作らない。
        imageView.contentMode = .scaleAspectFill
        // 元の大きさの画像をタイムラインの写真ほどに縮めて描くと、既定の線形の縮小では細い線が間引かれて模様が乱れる。
        // ビューアの開閉では、縮めた複製からタイムラインのサムネイルへ着地の一コマで替わるため、乱れが消える瞬間が見える。
        imageView.layer.minificationFilter = .trilinear
        blendView.contentMode = .scaleAspectFill
        blendView.layer.minificationFilter = .trilinear
        blendView.alpha = 0
        paperView.backgroundColor = paperColor
        paperView.alpha = 0
        dimView.backgroundColor = .black
        dimView.alpha = 0
        for view in [paperView, imageView, blendView, dimView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperView.frame = bounds
        dimView.frame = bounds
        let inner = bounds.insetBy(dx: paperBorder, dy: paperBorder)
        imageView.frame = MediaFocus.fillFrame(imageSize: imageView.image?.size ?? inner.size, in: inner, focus: focus)
        blendView.frame = imageView.frame
    }
}
