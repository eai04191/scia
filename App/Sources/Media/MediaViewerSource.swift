import SciaCore
import UIKit

/// ビューアを開閉するときに、画像を広げ始め、縮めて戻す先のビュー。投稿の添付ファイルのサムネイルのほか、プロフィールのアイコンやヘッダー画像がなる。
/// ビューアは、このビューの枠と角の丸み（`layer.cornerRadius`と`layer.cornerCurve`）から、画像の複製を動かす。
@MainActor
protocol MediaViewerSource: UIView {
    /// 描いている画像。ビューアの開閉で、まだ画像を描いていないページの代わりに動かす。
    var thumbnailImage: UIImage? { get }
    /// 読み込んだ画像。ぼかしなどの仮の下地は含まない。ビューアで元の画像が届くまでの下地にする。
    var loadedThumbnail: UIImage? { get }
    /// 投稿者が付けた焦点。このビューは焦点に合わせて切り抜いていて、ビューアの複製もこのビューの近くでは同じように切り抜く。
    var thumbnailFocus: MediaFocus? { get }
    /// 画像の奥に敷いている背景の色。透明な部分のある画像では、この色が透けて見える。
    var placeholderColor: UIColor? { get }
    /// 画像の上に重ねている表示の複製。ビューアが動かす画像の複製に載せて、このビューとのあいだを一緒に動かす。重ねた表示がなければ空のビューを返す。
    func makeDecorationCopy() -> UIView
    /// ビューアがこのビューとのあいだで画像を動かしている間、見えなくする。
    /// 透明にすると触れても反応しなくなり、閉じる途中にタップし直しても開けないため、空のマスクで隠す。
    var isConcealedForViewer: Bool { get set }
    /// このビューの上に重なっているビュー。手前にあるものほど後ろに並べる。ビューアは画像の複製のさらに手前に、これらの複製を重ねる。
    var overlappingViews: [UIView] { get }
    /// `id`の添付ファイルを描いているか。一覧で重ねた写真は、何番目の添付ファイルでも手前の写真を開閉の起点にするため、起点が別の添付ファイルを描いていることがある。
    /// 描いていなければ、ビューアは起点の枠と角の丸みだけを使い、画像、焦点、重ねた表示は使わない。
    func showsAttachment(_ id: MediaAttachment.ID) -> Bool
}

extension MediaViewerSource {
    var overlappingViews: [UIView] { [] }
    var thumbnailFocus: MediaFocus? { nil }
    /// 添付ファイルを1つしか描かない起点（プロフィールの画像やリンクカードの画像）は、いつも開いたものを描いている。
    func showsAttachment(_ id: MediaAttachment.ID) -> Bool { true }
}

extension UIView {
    /// `space`から見た、このビューの回転の角度（ラジアン）。祖先のビューの回転も含める。拡大や縮小はしていないものとする。
    /// 一覧で重ねた写真のように回して置いた起点から、ビューアが画像を回しながら動かすときに使う。
    func rotation(in space: UIView) -> CGFloat {
        let origin = convert(CGPoint.zero, to: space)
        let unitX = convert(CGPoint(x: 1, y: 0), to: space)
        return atan2(unitX.y - origin.y, unitX.x - origin.x)
    }

    /// `space`の座標で、回転を戻したときの枠。中心はこのビューの中心のまま、大きさは`bounds`の大きさ。
    /// 回したビューを`convert(bounds, to:)`で移すと、外側に接する大きめの四角になるため。
    func unrotatedFrame(in space: UIView) -> CGRect {
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: space)
        return CGRect(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2, width: bounds.width, height: bounds.height)
    }

    /// 親ビューの座標で、回転を戻したときの枠。回したビューの`frame`は外側に接する四角になり、置き直しにも使えないため、中心と大きさから求める。
    var unrotatedFrame: CGRect {
        CGRect(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2, width: bounds.width, height: bounds.height)
    }

    /// 今の回転を保ったまま、回転を戻したときの枠が`frame`（親ビューの座標）になるよう置く。
    func setUnrotatedFrame(_ frame: CGRect) {
        bounds.size = frame.size
        center = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// 回転を戻したときの枠を`frame`（親ビューの座標）にし、`rotation`（ラジアン）だけ回して置く。
    func place(unrotatedFrame frame: CGRect, rotation: CGFloat) {
        setUnrotatedFrame(frame)
        transform = rotation == 0 ? .identity : CGAffineTransform(rotationAngle: rotation)
    }

    /// 自分の`transform`の回転の角度（ラジアン）。
    var transformRotation: CGFloat {
        atan2(transform.b, transform.a)
    }
}

/// 画像を1枚描くだけのビュー。プロフィールのアイコンやヘッダー画像のように、上に重ねる表示がない。
extension MediaViewerSource where Self: UIImageView {
    var thumbnailImage: UIImage? { image }
    var loadedThumbnail: UIImage? { image }

    var placeholderColor: UIColor? {
        backgroundColor?.resolvedColor(with: traitCollection)
    }

    func makeDecorationCopy() -> UIView {
        let container = UIView(frame: bounds)
        container.isUserInteractionEnabled = false
        return container
    }

    var isConcealedForViewer: Bool {
        get { layer.mask != nil }
        set { layer.mask = newValue ? CALayer() : nil }
    }
}
