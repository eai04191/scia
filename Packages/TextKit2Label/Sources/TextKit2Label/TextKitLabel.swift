public import Foundation
public import UIKit

/// UILabelの代わりに、TextKit 2で文字を並べて描けるラベル。`drawsWithTextKit`がfalseなら、UILabelのまま描く。
/// どちらで描くときも、UILabelと同じ位置に文字が並ぶTextKit 2の並び（`textLayout(of:)`）を出し、押した文字や文字の枠を求められる。
/// UILabelは文字の配置を公開しないため、同じ文字列と幅でTextKit 2に並べ直して位置を求める。
/// 並べる手順は`TextKitLabelLayout`に置く。
open class TextKitLabel: UILabel {
    /// 置く側が最後に`attributedText`に入れた文字列そのもの。`text`を入れたらnil。先に並べた結果がこの文字列のものかを見分けるのに使う。
    public private(set) var assignedText: NSAttributedString?

    override open var attributedText: NSAttributedString? {
        get { drawsWithTextKit ? textKitText : super.attributedText }
        set {
            assignedText = newValue
            preparedLayout = nil
            // 測った結果は、文字列を入れる前に捨てる。UILabelは文字列を入れる中で大きさを測り直して覚えるため、
            // あとで捨てると、使い回したラベルが前の文字列で測った大きさのままになる。
            invalidateTextLayout()
            attributedTextWillChange()
            setDisplayedText(newValue)
        }
    }

    /// 置く側が中身の違う文字列を入れる前に呼ぶ。文字列から測った結果を持つ派生のラベルが、ここで捨てる。
    /// UILabelは文字列を入れる中で大きさを測り直して覚えるため、入れたあとに捨てると、前の文字列で測った結果を使われる。
    open func attributedTextWillChange() {}

    /// TextKit 2で描くときは、UILabelが持つ空白1文字ではなく、描いている文字列を読み書きする。
    override open var text: String? {
        get { drawsWithTextKit ? textKitText?.string : super.text }
        set {
            invalidateTextLayout()
            attributedTextWillChange()
            assignedText = nil
            preparedLayout = nil
            if drawsWithTextKit {
                setDisplayedText(newValue.map { NSAttributedString(string: $0) })
            } else {
                super.text = newValue
            }
            invalidateTextLayout()
        }
    }

    override open var numberOfLines: Int {
        didSet {
            invalidateTextLayout()
            setNeedsLayout()
        }
    }

    override open var lineBreakMode: NSLineBreakMode {
        didSet {
            preparedLayout = nil
            invalidateTextLayout()
            setNeedsLayout()
        }
    }

    // MARK: - 並び

    /// 並べ直した結果。文字を探すたびや、並べ直すたびに作らないよう、文字列と幅が変わるまで使い回す。
    private var layoutCache: TextLayout? {
        didSet {
            // 並べ直すときは、測った大きさも捨てる。
            if layoutCache == nil { textKitMetrics = [:] }
        }
    }

    /// 並べた結果と測った大きさを捨てる。描いている文字列や、並べ方に関わる値を変えたときに呼ぶ。
    public final func invalidateTextLayout() {
        layoutCache = nil
    }

    /// 先に並べた結果（`usePreparedLayout`）を、描く並びにも使ってよいか。大きさを測るときは、これによらず使う。
    /// 派生のラベルが、置く側が渡した文字列と大きさは同じで中身の違う文字列を描いているときに、falseにする。
    open var canDrawPreparedLayout: Bool { true }

    /// `attributedText`をラベルと同じ幅で並べた結果。幅か画面の向きが変わったときだけ並べ直す。
    public final func textLayout(of attributedText: NSAttributedString) -> TextLayout {
        let direction = effectiveUserInterfaceLayoutDirection
        if let layoutCache, layoutCache.width == bounds.width, layoutCache.direction == direction {
            return layoutCache
        }
        let layout = (canDrawPreparedLayout ? preparedLayout?.entry(width: bounds.width, maximumLines: numberOfLines)?.layout : nil)
            ?? makeTextLayout(of: attributedText, width: bounds.width, maximumLines: numberOfLines)
        layoutCache = layout
        return layout
    }

    private func makeTextLayout(of attributedText: NSAttributedString, width: CGFloat, maximumLines: Int) -> TextLayout {
        TextKitLabelLayout.layout(of: attributedText, width: width, maximumLines: maximumLines, style: textKitStyle)
    }

    /// TextKit 2で並べるときに使う、ラベルの値。
    public final var textKitStyle: TextKitLabelLayout.Style {
        TextKitLabelLayout.Style(
            font: font,
            textColor: textColor,
            lineBreakMode: lineBreakMode,
            direction: effectiveUserInterfaceLayoutDirection,
            displayScale: traitCollection.displayScale > 0 ? traitCollection.displayScale : 1,
            overlaysGlyphs: drawsWithTextKit
        )
    }

    // MARK: - 先に並べた結果

    /// メインスレッドの外で先に並べた結果。置く側が渡した文字列と、ラベルの値が同じときだけ持ち、文字列が替わったら捨てる。
    private var preparedLayout: PreparedTextLayout?

    /// 先に並べた結果を、今の文字列の並びとして使う。文字列を入れたあとに渡す。
    /// 並べた文字列が今の文字列と同じものでないか、並べたときのラベルの値（書体や色、行の切り方、文字の向き）が今と違えば使わない。
    public final func usePreparedLayout(_ prepared: PreparedTextLayout?) {
        guard let prepared, drawsWithTextKit, prepared.source === assignedText, prepared.style == textKitStyle else {
            preparedLayout = nil
            return
        }
        guard prepared !== preparedLayout else { return }
        preparedLayout = prepared
        invalidateTextLayout()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// 先に並べた結果の幅。本文の幅が決まる前に、ベースラインを置くのに使う。先に並べていなければnil。
    public final var preparedLayoutWidth: CGFloat? {
        preparedLayout?.width
    }

    // MARK: - TextKit 2で描く

    /// TextKit 2で描くときの、描いている文字列。UILabelが自分のフォントと色で埋めるのと同じく、フォントと色のない部分を埋めてある。
    /// UILabelには持たせない。UILabelは文字列を入れるたびに、自分で並べ直してベースラインを求めるため。
    private var textKitText: NSAttributedString?

    /// 描いている文字列を替える。置く側が渡した文字列（`assignedText`）は変えない。派生のラベルが、渡された文字列を差し替えて描くときにも使う。
    /// TextKit 2で描くときは、UILabelには空白1文字だけを渡す。
    /// 空にするとUILabelが描画を省くため、1文字にする。同じ1文字を渡し直してもUILabelは大きさを測り直さないので、測り直しと描き直しは自分で頼む。
    public final func setDisplayedText(_ text: NSAttributedString?) {
        guard drawsWithTextKit else {
            super.attributedText = text
            return
        }
        textKitText = text.map { TextKitLabelLayout.filled($0, style: textKitStyle) }
        if super.attributedText?.string != Self.textKitPlaceholder {
            super.attributedText = NSAttributedString(string: Self.textKitPlaceholder)
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    private static let textKitPlaceholder = " "

    /// TextKit 2で描くときは、UILabelが持つ空白1文字ではなく、描いている文字列を読み上げる。置く側が決めた文言があれば、そちらを使う。
    /// 置く側が決めていないときのUILabelの文言は、アクセシビリティが動いていれば空白1文字、動いていなければnilになる。どちらも描いている文字列に替え、端末の設定によらず同じ文言を返す。
    override open var accessibilityLabel: String? {
        get {
            let label = super.accessibilityLabel
            return drawsWithTextKit && (label == nil || label == Self.textKitPlaceholder) ? textKitText?.string : label
        }
        set { super.accessibilityLabel = newValue }
    }

    /// UILabelではなく、TextKit 2で並べて描く。大きさも、位置を読むのと同じ並べ方で測る。
    /// UILabelは端末で長い段落の改行位置を段落全体から選び、その計算が重い。行を組み立てるたびに、大きさ、ベースライン、描画で何度も並べるため、
    /// 長い本文の行でフレームが落ちた。TextKit 2はその計算をせず、並べた結果を幅と行数ごとに使い回す。
    /// UILabelのベースライン（`firstBaselineAnchor`など）は、TextKit 2の並びを使わずにUILabelが並べ直して求めるので、置く側は使わず、`textKitBaselines(width:)`で置く。
    open var drawsWithTextKit = false {
        didSet {
            guard drawsWithTextKit != oldValue else { return }
            preparedLayout = nil
            // 描いている文字列を、新しい描き方の置き場所へ移す。
            let shown = oldValue ? textKitText : super.attributedText
            if drawsWithTextKit {
                setDisplayedText(shown)
            } else {
                textKitText = nil
                super.attributedText = shown
            }
            invalidateTextLayout()
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    private struct TextKitMetricsKey: Hashable {
        let width: CGFloat
        let maximumLines: Int
    }

    /// TextKit 2で並べた結果の大きさとベースライン。幅と行数ごとに、文字列が変わるまで使い回す。
    private var textKitMetrics: [TextKitMetricsKey: TextKitLabelLayout.Metrics] = [:]

    private func textKitMetrics(width: CGFloat, maximumLines: Int) -> TextKitLabelLayout.Metrics? {
        guard let attributedText, attributedText.length > 0 else { return nil }
        let key = TextKitMetricsKey(width: width, maximumLines: maximumLines)
        if let metrics = textKitMetrics[key] { return metrics }
        // 先に並べてあれば、その大きさを使う。描く文字列を差し替えていても、置く側は大きさの同じものに差し替えるので、大きさは変わらない。
        if let prepared = preparedLayout?.entry(width: width, maximumLines: maximumLines) {
            textKitMetrics[key] = prepared.metrics
            return prepared.metrics
        }
        // 描くのと同じ幅と行数なら、描くときの並びを使い回す。並びは文字列を入れる前に捨てるので、前の文字列の並びは残らない。
        let layout = width == bounds.width && maximumLines == numberOfLines
            ? textLayout(of: attributedText)
            : makeTextLayout(of: attributedText, width: width, maximumLines: maximumLines)
        guard let metrics = TextKitLabelLayout.metrics(of: layout, displayScale: textKitStyle.displayScale) else { return nil }
        textKitMetrics[key] = metrics
        return metrics
    }

    /// TextKit 2で行数を限らずに並べたときの行数。
    public final func textKitLineCount(width: CGFloat) -> Int {
        textKitMetrics(width: width, maximumLines: 0)?.lineCount ?? 0
    }

    /// TextKit 2で`width`の幅に今の行数で並べたときの、上端から最初の行のベースラインまでと、最後の行のベースラインから下端まで。
    /// 文字がなければ、どちらも0。
    public final func textKitBaselines(width: CGFloat) -> (first: CGFloat, lastFromBottom: CGFloat) {
        textKitMetrics(width: width, maximumLines: numberOfLines).map { ($0.firstBaseline, $0.lastBaselineFromBottom) } ?? (0, 0)
    }

    /// TextKit 2で`width`の幅に今の行数で並べたときの、最初の行と最後の行の文字の範囲。
    /// 置く側が最後に入れた文字列（`assignedText`）と`text`の長さが違うか、文字がなければnil。
    /// 置く側は、属性だけを変えた文字列（「…」で切る段落スタイルにしたものなど）を入れることがあるので、同じオブジェクトかでは比べない。
    /// 長さの違う文字列（テキストを選択している間に、URLを元の文字に戻した本文）の範囲を渡すと、位置がずれる。
    public final func textKitLineRanges(of text: NSAttributedString, width: CGFloat) -> (first: NSRange, last: NSRange)? {
        guard assignedText?.length == text.length else { return nil }
        return textKitMetrics(width: width, maximumLines: numberOfLines).map { ($0.firstLineRange, $0.lastLineRange) }
    }

    override open func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        guard drawsWithTextKit else { return super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines) }
        // 文字がなければ、UILabelに渡した空白1文字ではなく、空の大きさを返す。UILabelも、空の文字列では高さを0にする。
        guard let metrics = textKitMetrics(width: bounds.width, maximumLines: numberOfLines) else {
            return CGRect(origin: bounds.origin, size: .zero)
        }
        return CGRect(origin: bounds.origin, size: CGSize(width: min(metrics.size.width, bounds.width), height: min(metrics.size.height, bounds.height)))
    }

    override open func drawText(in rect: CGRect) {
        guard drawsWithTextKit, let attributedText, attributedText.length > 0, let context = UIGraphicsGetCurrentContext() else {
            super.drawText(in: rect)
            return
        }
        let layout = textLayout(of: attributedText)
        context.saveGState()
        // 幅より大きい絵文字は、UILabelと同じくラベルの左右の端で切る。切らないと、本文の右に並べた添付ファイルに重なる。
        // 上下は切らない。UILabelも、積み重なる結合文字のように行の外へ伸びる字形は、ラベルの外まで描く。
        context.clip(to: CGRect(x: 0, y: -bounds.height, width: bounds.width, height: bounds.height * 3))
        // 重ねて描く字形は、文字より先に描く。TextKitは場所取りの上にも、元の文字の取り消し線や下線を引くので、その線が字形の上に乗る。
        TextKitLabelLayout.drawOverlaidGlyphs(of: layout, in: context, below: bounds.maxY)
        layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard fragment.layoutFragmentFrame.minY < bounds.maxY else { return false }
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return true
        }
        context.restoreGState()
    }

    /// TextKit 2で描くときに、大きくした絵文字などを重ねて描く位置（ベースラインの左端）。ラベルの座標で返す。
    public final var overlaidGlyphOrigins: [CGPoint] {
        guard drawsWithTextKit, let attributedText, attributedText.length > 0 else { return [] }
        return TextKitLabelLayout.overlaidGlyphs(of: textLayout(of: attributedText), below: bounds.maxY).map(\.origin)
    }

    // MARK: - 文字の位置

    /// ラベルの座標`point`にある文字の位置。文字の上でなければnil。
    public final func characterIndex(at point: CGPoint) -> Int? {
        guard let attributedText, attributedText.length > 0, bounds.contains(point) else { return nil }
        let layout = textLayout(of: attributedText)
        let contentStorage = layout.contentStorage
        let layoutManager = layout.layoutManager

        guard let fragment = layoutManager.textLayoutFragment(for: point),
              let paragraphStart = fragment.textElement?.elementRange?.location
        else { return nil }
        let pointInFragment = CGPoint(x: point.x - fragment.layoutFragmentFrame.minX, y: point.y - fragment.layoutFragmentFrame.minY)
        // 行末より右や最終行より下を押しても、いちばん近い文字が返るため、文字の枠の中かを確かめる。
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(pointInFragment) }),
              pointInFragment.x <= line.typographicBounds.minX + line.typographicBounds.width
        else { return nil }
        let pointInLine = CGPoint(x: pointInFragment.x - line.typographicBounds.minX, y: pointInFragment.y - line.typographicBounds.minY)
        let indexInLine = line.characterIndex(for: pointInLine)
        guard indexInLine != NSNotFound,
              let boundary = contentStorage.location(paragraphStart, offsetBy: indexInLine)
        else { return nil }
        let boundaryIndex = contentStorage.offset(from: contentStorage.documentRange.location, to: boundary)
        // 返るのは文字と文字の境目で、押した文字の前か後ろかは書く向きで変わる。境目の前後の文字のうち、描かれた枠に押した点が入るほうを選ぶ。
        let candidates = [boundaryIndex, boundaryIndex - 1].filter { 0 <= $0 && $0 < attributedText.length }
        return candidates.first {
            characterFrame(at: $0, in: attributedText, contentStorage: contentStorage, layoutManager: layoutManager)?.contains(point) ?? false
        }
    }

    /// `index`（UTF-16の位置）を含む文字が描かれる枠。ラベルの座標で返す。
    /// 枠はUTF-16の1単位ではなく、`index`を含む書記素クラスタ全体で測る。🅰のようにサロゲートペアで書く絵文字や、
    /// `U+FE0F`の付いた絵文字は1単位では描かれる枠がなく、絵文字のリンクを押しても当たらなかったため。
    public final func characterFrame(
        at index: Int, in text: NSAttributedString, contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager
    ) -> CGRect? {
        let cluster = (text.string as NSString).rangeOfComposedCharacterSequence(at: index)
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: cluster.location),
              let end = contentStorage.location(start, offsetBy: cluster.length),
              let range = NSTextRange(location: start, end: end)
        else { return nil }
        var frame: CGRect?
        layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
            frame = frame.map { $0.union(segment) } ?? segment
            return true
        }
        return frame
    }
}
