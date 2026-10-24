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
}

extension MediaViewerSource {
    var overlappingViews: [UIView] { [] }
    var thumbnailFocus: MediaFocus? { nil }
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
