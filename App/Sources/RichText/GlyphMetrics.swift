import UIKit

/// 字面の枠を測る値と関数。字面から測って部品のgapを並べるのに使う。
enum GlyphMetrics {
    /// 和文の字面の枠（em枠）の、ベースラインから上端と下端までの距離。日本語の字面はcapHeightより上に出るため、em枠で測る。
    /// em枠はベースラインの上0.88em、下0.12emにあるとみなす。
    static let emBoxAscent: CGFloat = 0.88
    static let emBoxDescent: CGFloat = 0.12

    /// 先頭の文字の、ベースラインから字面の上端まで。絵文字が字面より上へ伸びていれば、その上端まで。
    /// 絵文字を文字の行より大きくした段落は、絵文字が字面の中心から上下へ伸び、行が文字の行より高くなる。
    /// 字面だけで測ると、1行目の絵文字が上の部品（名前の行）に重なるため、絵文字の上端で測る。
    /// 字面に、書体のascenderを超えた分だけを足すと、ascenderが字面より高いぶん絵文字の上端に届かず、上の部品との間隔が設定より狭くなる。
    /// UILabelで描くラベルは段落のどの行も同じ高さに広げるので（`RichTextRenderer`の`minimumLineHeight`）、絵文字が1行目になくても最初の段落の絵文字で測る。
    /// 段落の中の改行で区切った行は、高さが違えば`RichTextRenderer`が段落に分けるので、最初の段落は改行の前の行だけになる。
    /// - Parameter width: 並べる幅。渡せば、行より広いカスタム絵文字は縮めて置く大きさで測る。
    /// - Parameter firstLine: TextKit 2で並べた最初の行の文字の範囲（`TextKitLabel.textKitLineRanges(of:width:)`）。TextKit 2は行ごとに高さを決めるので、渡せばその行の絵文字で測る。
    static func textTopInset(of text: NSAttributedString, width: CGFloat? = nil, firstLine: NSRange? = nil) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let range = firstLine ?? (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        guard let font = RichTextRenderer.textFont(in: text, range: range) else { return 0 }
        return max(font.pointSize * emBoxAscent, RichTextRenderer.emojiExtent(in: text, range: range, width: width).above)
    }

    /// 最後の文字の、ベースラインから字面の下端まで。最後の段落の絵文字が字面より下へ伸びていれば、その下端まで。
    /// - Parameter isTruncated: 行数で切って描くときはtrue。最後に見える行がどの段落か分からないため、全体の絵文字で測る。
    ///   切れた先にだけ大きい絵文字があると、下の部品とのあいだが絵文字の分だけ広く空くが、重なるよりよいので受け入れる。
    ///   長い本文を切る決まり（`PostBodyContent.truncation`）では、falseのまま最後の段落で測る。切るかどうかは並べる幅で決まるため、
    ///   全体で測ると、切っていないほとんどの投稿でも途中の段落の絵文字の分だけ下の部品とのあいだが広がる。切ったときは、見える最後の行に、
    ///   最後の段落より下へ伸びる大きい絵文字があると、その差の分だけ下の部品に近づく。幅が分かるのは並べるときで、あいだの制約を作る中身の適用では分からず、
    ///   並べるときに制約を変えると、行の高さがタイムラインの測った高さと食い違うため、対応しない。
    /// - Parameter width: 並べる幅。渡せば、行より広いカスタム絵文字は縮めて置く大きさで測る。
    /// - Parameter lastLine: TextKit 2で並べた最後の行の文字の範囲（`TextKitLabel.textKitLineRanges(of:width:)`）。渡せばその行の絵文字で測る。`isTruncated`なら使わない。
    static func textBottomInset(of text: NSAttributedString, isTruncated: Bool = false, width: CGFloat? = nil, lastLine: NSRange? = nil) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let range = isTruncated
            ? NSRange(location: 0, length: text.length)
            : lastLine ?? (text.string as NSString).paragraphRange(for: NSRange(location: text.length - 1, length: 0))
        guard let font = RichTextRenderer.textFont(in: text, range: range, fromEnd: true) else { return 0 }
        return max(font.pointSize * emBoxDescent, RichTextRenderer.emojiExtent(in: text, range: range, width: width).below)
    }
}

extension UILabel {
    /// 最初のベースラインから字面の上端まで。文字列に書体の属性がなければ、ラベルの書体で測る。
    var glyphsTopInset: CGFloat {
        let inset = attributedText.map { GlyphMetrics.textTopInset(of: $0) } ?? 0
        return inset > 0 ? inset : font.pointSize * GlyphMetrics.emBoxAscent
    }

    /// 最後のベースラインから字面の下端まで。文字列に書体の属性がなければ、ラベルの書体で測る。
    var glyphsBottomInset: CGFloat {
        let inset = attributedText.map { GlyphMetrics.textBottomInset(of: $0) } ?? 0
        return inset > 0 ? inset : font.pointSize * GlyphMetrics.emBoxDescent
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
