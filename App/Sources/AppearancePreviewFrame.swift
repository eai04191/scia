import UIKit

extension UIView {
    /// 表示中なら、このビューの枠を`space`の座標で返す。大きさを0にした部品も、場所を示せるよう、幅や高さが0の枠を返す。
    func previewFrame(in space: UIView) -> [CGRect]? {
        guard !isHidden, window != nil || superview != nil else { return nil }
        return [convert(bounds, to: space)]
    }
}

extension UIImageView {
    /// 表示中なら、制約で置く枠（alignment rect）を`space`の座標で返す。SF Symbolsの記号は、絵によって枠の外に描く余白があり、
    /// ビューの枠で測ると、制約で決めたすき間より狭く測れるため、記号の枠はこちらで測る。
    func previewAlignmentFrame(in space: UIView) -> [CGRect]? {
        guard !isHidden, window != nil || superview != nil else { return nil }
        return [convert(alignmentRect(forFrame: bounds), to: space)]
    }
}
