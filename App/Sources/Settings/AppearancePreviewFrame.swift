import UIKit

extension UIView {
    /// 表示中なら、このビューの枠を`space`の座標で返す。大きさを0にした部品も、場所を示せるよう、幅や高さが0の枠を返す。
    func previewFrame(in space: UIView) -> [CGRect]? {
        guard !isHidden, window != nil || superview != nil else { return nil }
        return [convert(bounds, to: space)]
    }
}
