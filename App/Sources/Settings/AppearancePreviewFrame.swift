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

extension UILabel {
    /// 最初のベースラインから字面の上端まで。文字列に書体の属性がなければ、ラベルの書体で測る。
    var glyphsTopInset: CGFloat {
        let inset = attributedText.map { PostBodyView.textTopInset(of: $0) } ?? 0
        return inset > 0 ? inset : font.pointSize * PostBodyView.emBoxAscent
    }

    /// 最後のベースラインから字面の下端まで。文字列に書体の属性がなければ、ラベルの書体で測る。
    var glyphsBottomInset: CGFloat {
        let inset = attributedText.map { PostBodyView.textBottomInset(of: $0) } ?? 0
        return inset > 0 ? inset : font.pointSize * PostBodyView.emBoxDescent
    }
}

/// ラベルの最初と最後のベースラインの位置を持つガイド。字面から測って並べた部品の、字面の枠を「投稿の見た目」のプレビューで示すのに使う。
@MainActor
final class LabelBaselineGuides {
    private let label: UILabel
    private let first = UILayoutGuide()
    private let last = UILayoutGuide()

    /// `label`を子に持つ`view`にガイドを足す。
    init(of label: UILabel, in view: UIView) {
        self.label = label
        view.addLayoutGuide(first)
        view.addLayoutGuide(last)
        NSLayoutConstraint.activate([
            first.heightAnchor.constraint(equalToConstant: 0),
            first.topAnchor.constraint(equalTo: label.firstBaselineAnchor),
            last.heightAnchor.constraint(equalToConstant: 0),
            last.topAnchor.constraint(equalTo: label.lastBaselineAnchor),
        ])
    }

    /// 表示中なら、ラベルの字面の枠を`space`の座標で返す。上端は最初のベースラインから、下端は最後のベースラインから、並びと同じくem枠で測る。
    /// - Parameter width: 文字のある幅だけを示すときの幅。nilならラベルの幅。
    func glyphsFrame(in space: UIView, width: CGFloat? = nil) -> [CGRect]? {
        guard let frame = label.previewFrame(in: space)?.first, let text = label.attributedText, text.length > 0, let owner = first.owningView else { return nil }
        let top = owner.convert(CGPoint(x: 0, y: first.layoutFrame.minY), to: space).y - label.glyphsTopInset
        let bottom = owner.convert(CGPoint(x: 0, y: last.layoutFrame.minY), to: space).y + label.glyphsBottomInset
        return [CGRect(x: frame.minX, y: top, width: width.map { min(frame.width, $0) } ?? frame.width, height: max(bottom - top, 0))]
    }
}
