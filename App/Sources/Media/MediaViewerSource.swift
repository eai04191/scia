import UIKit

/// ビューアを開閉するときに、画像を広げ始め、縮めて戻す先のビュー。投稿の添付ファイルのサムネイルのほか、プロフィールのアイコンやヘッダー画像がなる。
/// ビューアは、このビューの枠と角の丸み（`layer.cornerRadius`と`layer.cornerCurve`）から、画像の写しを動かす。
@MainActor
protocol MediaViewerSource: UIView {
    /// 描いている画像。ビューアの開閉で、まだ画像を描いていないページの代わりに動かす。
    var thumbnailImage: UIImage? { get }
    /// 読み込んだ画像。ぼかしなどの仮の下地は含まない。ビューアで元の画像が届くまでの下地にする。
    var loadedThumbnail: UIImage? { get }
    /// 画像の奥に敷いている背景の色。透明な部分のある画像では、この色が透けて見える。
    var placeholderColor: UIColor? { get }
    /// 画像の上に重ねている印の写し。ビューアが動かす画像の写しに載せて、このビューとのあいだを一緒に動かす。印がなければ空のビューを返す。
    func makeDecorationCopy() -> UIView
    /// ビューアがこのビューとのあいだで画像を動かしている間、見えなくする。
    /// 透明にすると触れても反応しなくなり、閉じる途中に叩き直しても開けないため、空のマスクで隠す。
    var isConcealedForViewer: Bool { get set }
}
