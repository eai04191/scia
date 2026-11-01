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
            setNeedsDisplay()
        }
    }

    /// 字形が行の高さや幅からはみ出しても切れないよう、描く範囲を広げる幅。動かすかたまりだけに付ける。
    var overhang: CGFloat = 0 {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    /// 行を描く位置を、ビューの中でずらす長さ。動かすかたまりで、ビューの枠を画素の境目に置いたまま、文字を本物と同じ端数の位置に描くのに使う。
    var phase: CGPoint = .zero {
        didSet {
            guard phase != oldValue else { return }
            setNeedsDisplay()
        }
    }

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let fadeMask = CAGradientLayer()
    private var fragment: NSTextLayoutFragment?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        let container = NSTextContainer(size: CGSize(width: 100_000, height: 0))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        fadeMask.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: TextLineView, _) in
            view.setNeedsDisplay()
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
        setNeedsDisplay()
    }

    private var line: NSTextLineFragment? { fragment?.textLineFragments.first }

    /// 文字の幅。
    var textWidth: CGFloat { line?.typographicBounds.width ?? 0 }

    private var lineHeight: CGFloat { line?.typographicBounds.height ?? 0 }

    override var intrinsicContentSize: CGSize {
        CGSize(width: ceil(textWidth) + overhang * 2, height: ceil(lineHeight) + overhang * 2)
    }

    /// 行を描く位置。高さが行より大きければ、上下の真ん中に置く。
    private var lineOrigin: CGPoint {
        CGPoint(x: overhang + phase.x, y: ((bounds.height - lineHeight) / 2).rounded(.down) + phase.y)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        guard fadesTrailingEdge, textWidth > bounds.width + 0.5, bounds.width > 0 else {
            layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        let fade = min(Self.fadeWidth, bounds.width) / bounds.width
        let isRightToLeft = FadingLabel.isRightToLeft(attributedText.string)
        fadeMask.startPoint = CGPoint(x: isRightToLeft ? fade : 1 - fade, y: 0.5)
        fadeMask.endPoint = CGPoint(x: isRightToLeft ? 0 : 1, y: 0.5)
        CATransaction.commit()
        layer.mask = fadeMask
    }

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

    override func draw(_ rect: CGRect) {
        guard let fragment, let line, let context = UIGraphicsGetCurrentContext() else { return }
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
