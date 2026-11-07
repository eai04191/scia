import TextKit2Label
import UIKit

/// 1行の文字を、入力欄（UITextView）と同じTextKit 2で描くビュー。
///
/// 投稿欄の開閉では、カプセルの1行、入力欄の「いまどうしてる？」、その間を動く文字のかたまりを、どれもこのビューで描く。
/// 描き方が入力欄と同じなので、動き終えて本物に替えたコマで、字形や位置が変わらない。UILabelは、行の高さとベースラインの決め方が
/// 入力欄と違い、混ぜると替えたコマで文字が上下にずれるため使わない。
@MainActor
final class TextLineView: UIView {
    var attributedText = NSAttributedString() {
        didSet {
            guard !attributedText.isEqual(to: oldValue) else { return }
            layOutText()
        }
    }

    /// 入りきらないときに、「…」で切らず行末を透明へ向けてぼかす。入りきるときは何もかけない。
    var fadesTrailingEdge = false {
        didSet { setNeedsLayout() }
    }

    /// 行末をぼかす幅。タイムラインの名前（`FadingLabel`）と同じにする。
    static let fadeWidth: CGFloat = 20

    /// 描かない文字の範囲（UTF-16）。動かしているかたまりが描く文字を、本物で隠すのに使う。
    var concealedRanges: [Range<Int>] = [] {
        didSet {
            guard concealedRanges != oldValue else { return }
            canvas.setNeedsDisplay()
        }
    }

    /// 字形が行の高さや幅からはみ出しても切れないよう、描く範囲を広げる幅。動かすかたまりだけに付ける。
    var overhang: CGFloat = 0 {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            canvas.setNeedsDisplay()
        }
    }

    /// 行を描く位置を、ビューの中でずらす長さ。動かすかたまりで、ビューの枠を画素の境目に置いたまま、文字を本物と同じ端数の位置に描くのに使う。
    var phase: CGPoint = .zero {
        didSet {
            guard phase != oldValue else { return }
            setNeedsLayout()
            canvas.setNeedsDisplay()
        }
    }

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let fadeMask = CAGradientLayer()
    private var fragment: NSTextLayoutFragment?
    /// 文字を描くビュー。ビューの枠より上下に広く取り、本文のフォントより背の高い代替フォントの字形（ミャンマー文字の上など）が、
    /// 行の外へはみ出しても欠けないようにする。並べる大きさとベースラインの位置は、このビューの大きさによらない。
    private let canvas = TextLineCanvas()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        canvas.owner = self
        addSubview(canvas)
        let container = NSTextContainer(size: CGSize(width: 100_000, height: 0))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        fadeMask.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TextLineView, _) in
            view.canvas.setNeedsDisplay()
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: TextLineView, _) in
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
            view.canvas.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func layOutText() {
        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(attributedText)
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        fragment = nil
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            self.fragment = fragment
            return false
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        canvas.setNeedsDisplay()
    }

    private var line: NSTextLineFragment? { fragment?.textLineFragments.first }

    var textWidth: CGFloat { line?.typographicBounds.width ?? 0 }

    private var lineHeight: CGFloat { line?.typographicBounds.height ?? 0 }

    /// 文字の高さ。行の上端からベースラインを通り、文字の下端まで。
    /// TextKit 2の行の高さには、フォントの行間がベースラインの下に足されている。行の高さで上下の真ん中に置くと、その分だけ文字が上に寄るので、
    /// UILabelと同じく、ベースラインから下はCoreTextで測った長さにする（`TextKitLabelLayout.descent(of:)`）。
    private var textHeight: CGFloat {
        guard let line else { return 0 }
        return ascent + TextKitLabelLayout.descent(of: line)
    }

    private func roundedUpToPixel(_ value: CGFloat) -> CGFloat {
        let scale = traitCollection.displayScale
        return (value * scale).rounded(.up) / scale
    }

    /// 並べる大きさは、文字の高さ（`textHeight`）を画素の境目まで切り上げたもの。1pt単位で切り上げると、上下の真ん中に置いたときに、UILabelより最大1pt近く上に寄るため。
    override var intrinsicContentSize: CGSize {
        CGSize(width: ceil(textWidth) + overhang * 2, height: roundedUpToPixel(textHeight) + overhang * 2)
    }

    /// 行を描く位置。並べる大きさが文字より大きければ、文字の高さを上下の真ん中に置く。
    /// 真ん中に置く位置は1pt単位で切り捨てる。入力欄に重ねる「いまどうしてる？」は上端で置き、画素の境目まで切り上げた余りで、入力欄の1行目よりベースラインが下がらないようにするため。
    private var lineOrigin: CGPoint {
        CGPoint(x: overhang + phase.x, y: ((bounds.height - textHeight) / 2).rounded(.down) + phase.y)
    }

    /// 行の頭の文字の、ベースラインの左の点。ビューの中の座標。
    var baselineOrigin: CGPoint {
        guard let line else { return lineOrigin }
        return CGPoint(x: lineOrigin.x + line.locationForCharacter(at: 0).x, y: lineOrigin.y + line.glyphOrigin.y)
    }

    var ascent: CGFloat { line?.glyphOrigin.y ?? 0 }
    var descent: CGFloat { lineHeight - ascent }

    /// 行の頭から数えた、文字の境目ごとの横の位置。文字の数（UTF-16）より1つ多い。
    var boundaries: [CGFloat] {
        guard let line else { return [0] }
        return Self.boundaries(of: line, in: 0 ..< attributedText.length)
    }

    /// 行の`range`の文字の境目の位置を、`range`の頭の文字から数えて返す。`range`は行の文字列の中の位置。
    static func boundaries(of line: NSTextLineFragment, in range: Range<Int>) -> [CGFloat] {
        let start = line.locationForCharacter(at: range.lowerBound).x
        return (range.lowerBound ... range.upperBound).map { index in
            index >= line.characterRange.upperBound ? line.typographicBounds.width - start : line.locationForCharacter(at: index).x - start
        }
    }

    /// 字形が描かれる範囲の上端と下端。ビューの中の座標。
    private var inkVerticalRange: ClosedRange<CGFloat>? {
        guard let fragment, let line else { return nil }
        // 描く範囲（`renderingSurfaceBounds`）は、行のかたまりの左上を原点にする。`drawText(in:)`で行の左上を`lineOrigin`に描くのと同じだけずらす。
        let surface = fragment.renderingSurfaceBounds
        let offset = lineOrigin.y - line.typographicBounds.minY
        return (surface.minY + offset) ... (surface.maxY + offset)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 上下は字形が描かれる範囲まで広げ、横はビューの枠のままにする。横は、入りきらない文字を枠で切っているため。
        let ink = inkVerticalRange ?? 0 ... bounds.height
        let top = min(0, ink.lowerBound.rounded(.down))
        let canvasFrame = CGRect(x: 0, y: top, width: bounds.width, height: max(bounds.height, ink.upperBound.rounded(.up)) - top)
        if canvas.frame != canvasFrame {
            // 外側のアニメーションの中で並べ直しても、枠は動かさない。描いた中身は枠に合わせて伸び縮みするので、動かすと文字が縮んで見えるため。
            // 開閉で動かす文字のかたまりは、開閉の動きの中で初めて並べ直され、枠が0から育って、開き始めに文字が消えたように見えた。
            UIView.performWithoutAnimation {
                canvas.frame = canvasFrame
            }
            canvas.setNeedsDisplay()
        }
        guard fadesTrailingEdge, textWidth > bounds.width + 0.5, bounds.width > 0 else {
            layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // ぼかしは、文字を描くビューの広げた上下にも掛ける。
        fadeMask.frame = canvasFrame
        let fade = min(Self.fadeWidth, bounds.width) / bounds.width
        let isRightToLeft = FadingLabel.isRightToLeft(attributedText.string)
        fadeMask.startPoint = CGPoint(x: isRightToLeft ? fade : 1 - fade, y: 0.5)
        fadeMask.endPoint = CGPoint(x: isRightToLeft ? 0 : 1, y: 0.5)
        CATransaction.commit()
        layer.mask = fadeMask
    }

    /// 文字を描く範囲。ビューの中の座標。
    var drawingRect: CGRect { canvas.frame }

    /// 行末をぼかしているか。
    var isTruncated: Bool { layer.mask != nil }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        ranges.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { result, range in
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
    }

    /// 行を、このビューの座標で`context`に描く。
    func drawText(in context: CGContext) {
        guard let fragment, let line else { return }
        let origin = lineOrigin
        if !concealedRanges.isEmpty {
            // 隠す文字の枠を、描く範囲から抜く。色を透明にしても、色付きの絵文字は消えないため。
            let path = UIBezierPath(rect: bounds.insetBy(dx: -1000, dy: -1000))
            // 隣り合う範囲はつなげてから抜く。枠を少し広げて抜くので、別々に抜くと重なったところが偶奇の規則で描き戻されるため。
            for range in Self.merged(concealedRanges) {
                let clamped = range.clamped(to: 0 ..< attributedText.length)
                guard !clamped.isEmpty else { continue }
                let start = line.locationForCharacter(at: clamped.lowerBound).x
                let end = clamped.upperBound >= line.characterRange.upperBound ? line.typographicBounds.width : line.locationForCharacter(at: clamped.upperBound).x
                path.append(UIBezierPath(rect: CGRect(x: origin.x + start - 0.5, y: -1000, width: end - start + 1, height: bounds.height + 2000)))
            }
            path.usesEvenOddFillRule = true
            path.addClip()
        }
        context.translateBy(x: origin.x - fragment.layoutFragmentFrame.minX - line.typographicBounds.minX, y: origin.y - fragment.layoutFragmentFrame.minY - line.typographicBounds.minY)
        fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
    }
}

/// `TextLineView`の文字を描くビュー。描くのは`TextLineView`が受け持つ。
@MainActor
private final class TextLineCanvas: UIView {
    weak var owner: TextLineView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // `TextLineView`の座標で描くよう、このビューの位置の分だけずらす。
        context.translateBy(x: -frame.minX, y: -frame.minY)
        owner?.drawText(in: context)
    }
}
