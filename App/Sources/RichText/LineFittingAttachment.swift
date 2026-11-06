import UIKit

/// カスタム絵文字の添付。行の幅より広いときだけ、縦横比を保って行の幅まで縮めて置く。縮めるときは、縦の中心を`bounds`の中心に揃えたままにする。
/// 文字列は描く幅が分かる前に作るので、置く大きさはTextKitが並べるときに求める。`bounds`は縮める前の大きさのまま持つ。
/// UILabelも、TextKit 2で並べ直して位置を求めるときも、同じ`attachmentBounds`を呼ぶので、描く位置と求める位置は揃う。
/// TextKitが渡す行の幅は、字下げした段落でもコンテナの幅のままなので、段落の字下げを引く。
/// 行より広い絵文字は前の文字と同じ行に入らず、折り返した行の頭に置かれるので、折り返した行の字下げ（`headIndent`）で測る。
final class LineFittingAttachment: NSTextAttachment {
    /// 行の高さを決めた、本文の書体。縮めた絵文字に合わせて行の高さを付け直すのに使う（`RichTextRenderer.fittingWideEmojis`）。
    let lineFont: UIFont

    init(lineFont: UIFont) {
        self.lineFont = lineFont
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 同じ大きさで置く、`image`の添付。動く絵文字や線を重ねるために、透明な画像に差し替えるときに使う。
    /// 元が行の幅で縮める添付なら、差し替えたものも同じく縮める。
    static func placeholder(replacing attachment: NSTextAttachment, image: UIImage) -> NSTextAttachment {
        let placeholder = (attachment as? LineFittingAttachment).map { LineFittingAttachment(lineFont: $0.lineFont) } ?? NSTextAttachment()
        placeholder.image = image
        placeholder.bounds = attachment.bounds
        return placeholder
    }

    /// コンテナの幅`lineWidth`の、`paragraphStyle`の段落に置く大きさ。
    func placedBounds(lineWidth: CGFloat, paragraphStyle: NSParagraphStyle?) -> CGRect {
        Self.fitted(bounds, within: lineWidth - (paragraphStyle?.headIndent ?? 0))
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let storage = textContainer?.layoutManager?.textStorage
        let style = storage.flatMap { charIndex < $0.length ? $0.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle : nil }
        return placedBounds(lineWidth: Self.lineWidth(lineFrag, textContainer), paragraphStyle: style)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        placedBounds(lineWidth: Self.lineWidth(proposedLineFragment, textContainer), paragraphStyle: attributes[.paragraphStyle] as? NSParagraphStyle)
    }

    private static func lineWidth(_ lineFragment: CGRect, _ container: NSTextContainer?) -> CGFloat {
        lineFragment.width - 2 * (container?.lineFragmentPadding ?? 0)
    }

    /// `bounds`を、幅`width`に収まるよう縦横比を保って縮めた大きさ。収まっていれば、そのまま返す。
    /// 大きさを測るときは、幅を限らない（無限大）か、幅が決まる前の0で並べることがあるので、そのときも縮めない。
    static func fitted(_ bounds: CGRect, within width: CGFloat) -> CGRect {
        guard width > 0, width.isFinite, bounds.width > width else { return bounds }
        let height = bounds.height * width / bounds.width
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: width, height: height)
    }
}
