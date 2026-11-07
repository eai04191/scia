import CoreText
public import Foundation
public import UIKit

/// `TextKitLabel`がTextKit 2で文字を並べる手順。ラベルの値を受け取り、ラベルを使わずに並べる。
/// タイムラインの本文をメインスレッドの外で先に並べるときも、ラベルと同じ手順で並べるため、ラベルから分けている。
/// TextKit 2の部品は、同時に1つのスレッドだけが触るなら、メインスレッドの外で使ってよい（NSTextContainer.hの決まり）。
public enum TextKitLabelLayout {
    /// 並べ方を決める、ラベルの値。
    public struct Style: Equatable, Sendable {
        public var font: UIFont?
        public var textColor: UIColor?
        public var lineBreakMode: NSLineBreakMode
        public var direction: UIUserInterfaceLayoutDirection
        public var displayScale: CGFloat
        /// `.overlaidGlyphs`の文字を、場所取りの上に重ねて描く。TextKit 2で描くときだけtrueにする。
        /// UILabelで描くラベルでは、UILabelと同じ位置を求めるため、ふつうの文字のまま並べる。
        public var overlaysGlyphs = false

        public init(
            font: UIFont?, textColor: UIColor?, lineBreakMode: NSLineBreakMode, direction: UIUserInterfaceLayoutDirection,
            displayScale: CGFloat, overlaysGlyphs: Bool = false
        ) {
            self.font = font
            self.textColor = textColor
            self.lineBreakMode = lineBreakMode
            self.direction = direction
            self.displayScale = displayScale
            self.overlaysGlyphs = overlaysGlyphs
        }
    }

    /// 並べた結果の大きさとベースライン。
    public struct Metrics: Sendable {
        public let size: CGSize
        public let lineCount: Int
        /// 上端から最初の行のベースラインまで。
        public let firstBaseline: CGFloat
        /// 最後の行のベースラインから下端まで。
        public let lastBaselineFromBottom: CGFloat
        /// 最初の行と最後の行の文字の範囲。並べた文字列での位置で、並べる前に場所取りに置き換えても長さは変えないので、渡した文字列での位置と同じ。
        public let firstLineRange: NSRange
        public let lastLineRange: NSRange
    }

    /// フォントと色のない部分を、ラベルのフォントと色で埋めた文字列。UILabelは渡された文字列をこうして埋めてから並べる。
    public static func filled(_ text: NSAttributedString, style: Style) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: whole) { value, range, _ in
            if value == nil, let font = style.font { result.addAttribute(.font, value: font, range: range) }
        }
        result.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil, let textColor = style.textColor { result.addAttribute(.foregroundColor, value: textColor, range: range) }
        }
        return result
    }

    /// TextKit 2で描くラベルで、絵文字に合わせて付けた行の高さ（`minimumLineHeight`）を外した文字列。
    /// 行の高さは段落のどの行にも同じものが付くため、絵文字のある段落では、折り返した絵文字のない行まで高くなる。
    /// TextKit 2は、行の高さを行ごとに、その行の文字と添付から決める。大きくした絵文字は絵の枠の大きさの場所取り（`placingOverlaidGlyphs(_:)`）に、
    /// 行より広いカスタム絵文字は縮めて置く大きさ（`LineFittingAttachment`）にしてあるので、外せば絵文字のある行だけが絵文字の高さになる。
    /// UILabelで描くラベルでは外さない。UILabelは付けた行の高さで描くので、位置を求める並びも同じにする。
    public static func lineHeightsFromContent(_ text: NSAttributedString, style: Style) -> NSAttributedString {
        guard style.overlaysGlyphs else { return text }
        var result: NSMutableAttributedString?
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle, style.minimumLineHeight > 0,
                  let unlimited = style.mutableCopy() as? NSMutableParagraphStyle
            else { return }
            unlimited.minimumLineHeight = 0
            if result == nil { result = NSMutableAttributedString(attributedString: text) }
            result?.addAttribute(.paragraphStyle, value: unlimited, range: range)
        }
        return result ?? text
    }

    /// `filled(_:style:)`で埋めた文字列を、`width`の幅に`maximumLines`行まで並べる。0なら行数を限らない。
    public static func layout(of attributedText: NSAttributedString, width: CGFloat, maximumLines: Int, style: Style) -> TextLayout {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        // 高さは限らない。最後の行の下の行間まで数えるとラベルより高くなり、ラベルの高さで切ると最後の行が並ばない。
        let container = NSTextContainer(size: CGSize(width: width, height: 0))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maximumLines
        // 段落は折り返しにして、コンテナで最後の行だけを「…」で切る。最後の行に入りきらない単語も、UILabelと同じく「…」の前まで途中を並べる。
        container.lineBreakMode = truncationMode(of: attributedText, lineBreakMode: style.lineBreakMode) ?? style.lineBreakMode
        layoutManager.textContainer = container
        let fitted = lineHeightsFromContent(attributedText, style: style)
        let placed = style.overlaysGlyphs ? placingOverlaidGlyphs(fitted) : fitted
        contentStorage.attributedString = wrappingInsteadOfTruncating(aligned(placed, direction: style.direction))
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return TextLayout(
            width: width, direction: style.direction, contentStorage: contentStorage, layoutManager: layoutManager,
            overlaidText: placed === fitted ? nil : placed
        )
    }

    /// `.overlaidGlyphs`の文字を、書記素クラスタごとに、描く字形の枠と同じ大きさの場所取り（中身のない添付）に置き換えた文字列。
    /// TextKit 2は、行の高さを、行の文字の書体のascenderとdescenderとleadingで決める。大きくした絵文字は、書体が絵の上下に余白を持ち、
    /// 下げて描いた分もdescentに足されるため、その書体で並べると、行が絵より上下に高くなる。添付は、枠の大きさだけを行の高さにする。
    /// 文字の位置が変わらないよう、クラスタの2文字目からは幅のない文字にし、長さを変えない。字形は`drawOverlaidGlyphs(of:in:below:)`で重ねて描く。
    public static func placingOverlaidGlyphs(_ text: NSAttributedString) -> NSAttributedString {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.overlaidGlyphs, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let string = text.string as NSString
        for range in ranges {
            var location = range.location
            while location < NSMaxRange(range) {
                let cluster = NSIntersectionRange(string.rangeOfComposedCharacterSequence(at: location), range)
                location = NSMaxRange(cluster)
                var attributes = text.attributes(at: cluster.location, effectiveRange: nil)
                guard let font = attributes[.font] as? UIFont, let placeholderFont = attributes[.overlaidGlyphs] as? UIFont else { continue }
                let offset = attributes[.baselineOffset] as? CGFloat ?? 0
                let glyph = string.substring(with: cluster)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: font]))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                let placeholder = NSTextAttachment()
                placeholder.image = emptyImage
                placeholder.bounds = CGRect(x: 0, y: bounds.minY + offset, width: width, height: bounds.height)
                attributes[.font] = placeholderFont
                attributes[.baselineOffset] = nil
                attributes[.overlaidGlyphs] = nil
                var rest = attributes
                attributes[.attachment] = placeholder
                attributes[.overlaidGlyph] = OverlaidGlyph(text: glyph, font: font, color: attributes[.foregroundColor] as? UIColor, baselineOffset: offset)
                // 結合子やサロゲートペアの2文字目からは、幅のない文字にする。前の文字に付く結合用の文字（U+034F）にし、
                // 場所取りとのあいだで改行せず、後ろの文字との改行の機会は場所取りのものにする。語結合子（U+2060）では、後ろの文字との改行もなくなる。
                rest[.attachment] = nil
                rest[.overlaidGlyphFiller] = true
                let replacement = NSMutableAttributedString(string: "\u{FFFC}", attributes: attributes)
                replacement.append(NSAttributedString(string: String(repeating: "\u{034F}", count: cluster.length - 1), attributes: rest))
                result.replaceCharacters(in: cluster, with: replacement)
            }
        }
        return result
    }

    /// 場所取りに置き換えた文字の取り消し線と下線だけが見える文字列。場所取りに取り消し線も下線もなければnil。
    /// 字形を文字より先に描けないところ（文字の後ろに選択のハイライトを描くテキストビュー）で、字形のあとに重ねて、線を字形の上に乗せるのに使う。
    /// 同じ幅で並べれば元の文字列と同じ位置に並ぶよう、文字と添付は消さずに透明にする。
    public static func overlaidGlyphDecorations(_ placed: NSAttributedString) -> NSAttributedString? {
        let whole = NSRange(location: 0, length: placed.length)
        var decorated = false
        placed.enumerateAttributes(in: whole) { attributes, _, stop in
            let overlaid = attributes[.overlaidGlyph] != nil || attributes[.overlaidGlyphFiller] != nil
            if overlaid, attributes[.strikethroughStyle] != nil || attributes[.underlineStyle] != nil {
                decorated = true
                stop.pointee = true
            }
        }
        guard decorated else { return nil }
        let result = NSMutableAttributedString(attributedString: placed)
        placed.enumerateAttributes(in: whole) { attributes, range, _ in
            let color = attributes[.foregroundColor] as? UIColor
            if attributes[.overlaidGlyph] != nil || attributes[.overlaidGlyphFiller] != nil {
                if attributes[.strikethroughColor] == nil, let color { result.addAttribute(.strikethroughColor, value: color, range: range) }
                if attributes[.underlineColor] == nil, let color { result.addAttribute(.underlineColor, value: color, range: range) }
            } else {
                result.removeAttribute(.strikethroughStyle, range: range)
                result.removeAttribute(.underlineStyle, range: range)
            }
            if let attachment = attributes[.attachment] as? NSTextAttachment, attachment.image !== emptyImage {
                result.addAttribute(.attachment, value: LineFittingAttachment.placeholder(replacing: attachment, image: emptyImage), range: range)
            }
        }
        result.addAttribute(.foregroundColor, value: UIColor.clear, range: whole)
        return result
    }

    /// `placingOverlaidGlyphs(_:)`で場所取りに置き換えた文字列を、置き換える前の文字に戻した文字。
    public static func restoringOverlaidGlyphs(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            if attributes[.overlaidGlyphFiller] != nil { return }
            if let glyph = attributes[.overlaidGlyph] as? OverlaidGlyph {
                // 同じ絵文字が並ぶと1つの範囲にまとまるので、場所取り1つが1文字であることから数を戻す。
                result += String(repeating: glyph.text, count: range.length)
            } else {
                result += (text.string as NSString).substring(with: range)
            }
        }
        return result
    }

    /// 場所取りの添付に描く、透明な画像。
    private static let emptyImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

    /// `placingOverlaidGlyphs(_:)`で場所取りに置き換えた字形を、場所取りの位置に描く。`context`はラベルの座標で描く。
    public static func drawOverlaidGlyphs(of layout: TextLayout, in context: CGContext, below maxY: CGFloat) {
        for (glyph, origin) in overlaidGlyphs(of: layout, below: maxY) {
            glyph.draw(atBaseline: origin, in: context)
        }
    }

    /// 重ねて描く字形と、描く位置（ベースラインの左端）。ラベルの座標で返す。
    /// 行数で切られて並ばなかった場所取りと、「…」に置き換わった場所取りと、`maxY`より下の行は含めない。
    public static func overlaidGlyphs(of layout: TextLayout, below maxY: CGFloat) -> [(glyph: OverlaidGlyph, origin: CGPoint)] {
        guard let text = layout.overlaidText else { return [] }
        let contentStorage = layout.contentStorage
        let start = contentStorage.documentRange.location
        var result: [(glyph: OverlaidGlyph, origin: CGPoint)] = []
        text.enumerateAttribute(.overlaidGlyph, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let glyph = value as? OverlaidGlyph else { return }
            for index in range.location..<NSMaxRange(range) {
                guard let location = contentStorage.location(start, offsetBy: index),
                      let fragment = layout.layoutManager.textLayoutFragment(for: location),
                      let line = line(at: location, in: fragment, contentStorage: contentStorage)
                else { continue }
                let frame = fragment.frameForTextAttachment(at: location)
                let baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
                // 行の末尾で「…」に置き換わった場所取りも、添付の枠は返る。そのとき行の幅は「…」までになるので、枠が行の幅からはみ出るものは描かない。
                let lineBounds = line.typographicBounds.insetBy(dx: -0.5, dy: 0)
                guard !frame.isEmpty, frame.minX >= lineBounds.minX, frame.maxX <= lineBounds.maxX, baseline - glyph.font.lineHeight < maxY else { continue }
                result.append((glyph, CGPoint(x: fragment.layoutFragmentFrame.minX + frame.minX, y: baseline)))
            }
        }
        return result
    }

    private static func line(at location: any NSTextLocation, in fragment: NSTextLayoutFragment, contentStorage: NSTextContentStorage) -> NSTextLineFragment? {
        guard let paragraphStart = fragment.textElement?.elementRange?.location else { return nil }
        let index = contentStorage.offset(from: paragraphStart, to: location)
        return fragment.textLineFragments.first { NSLocationInRange(index, $0.characterRange) }
    }

    /// 並べた結果の大きさとベースライン。文字がなければnil。
    public static func metrics(of layout: TextLayout, displayScale scale: CGFloat) -> Metrics? {
        var lineCount = 0
        var maxX: CGFloat = 0
        var first: (baseline: CGFloat, range: NSRange)?
        var last: (baseline: CGFloat, line: NSTextLineFragment, range: NSRange)?
        let start = layout.layoutManager.documentRange.location
        layout.layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            // 行の文字の範囲は段落の中での位置なので、段落の頭の位置を足す。
            let paragraphStart = layout.contentStorage.offset(from: start, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
                let baseline = bounds.minY + line.glyphOrigin.y
                let range = NSRange(location: paragraphStart + line.characterRange.location, length: line.characterRange.length)
                lineCount += 1
                maxX = max(maxX, bounds.maxX)
                if first == nil { first = (baseline, range) }
                last = (baseline, line, range)
            }
            return true
        }
        guard let first, let last else { return nil }
        let height = ceil((last.baseline + descent(of: last.line)) * scale) / scale
        return Metrics(
            size: CGSize(width: ceil(maxX * scale) / scale, height: height),
            lineCount: lineCount,
            firstBaseline: first.baseline,
            lastBaselineFromBottom: height - last.baseline,
            firstLineRange: first.range,
            lastLineRange: last.range
        )
    }

    /// 行のベースラインから下端まで。TextKit 2の行の枠は、下にフォントのleadingを含むが、UILabelは最後の行の下にleadingを足さないため、
    /// 最後の行の下端は、UILabelと同じくCoreTextで測った行の下の長さで決める。
    /// カスタム絵文字の画像がベースラインより下へ伸びる行では、CoreTextの行の下の長さが、画像の下端までになる。
    public static func descent(of line: NSTextLineFragment) -> CGFloat {
        guard line.characterRange.length > 0 else { return line.typographicBounds.height - line.glyphOrigin.y }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(line.attributedString.attributedSubstring(from: line.characterRange)), &ascent, &descent, &leading)
        return descent
    }

    public static let truncatingModes: [NSLineBreakMode] = [.byTruncatingTail, .byTruncatingHead, .byTruncatingMiddle]

    /// ラベルか段落の「…」で切る設定。UILabelは文字列を入れると段落の設定で自分の`lineBreakMode`を上書きするので、段落の設定を先に見る。
    private static func truncationMode(of text: NSAttributedString, lineBreakMode: NSLineBreakMode) -> NSLineBreakMode? {
        var mode: NSLineBreakMode?
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, truncatingModes.contains(style.lineBreakMode) {
                mode = style.lineBreakMode
                stop.pointee = true
            }
        }
        return mode ?? (truncatingModes.contains(lineBreakMode) ? lineBreakMode : nil)
    }

    /// 段落の「…」で切る設定を、単語で折り返す設定に替えた文字列。
    /// UILabelは、行数を限ったときも折り返してから最後の行だけを「…」で切るが、TextKit 2は「…」で切る段落を折り返さずに1行に並べる。
    /// そのまま並べると、2行目より後の文字の位置がUILabelの描画と合わないため、段落は折り返して並べ、最後の行はコンテナの設定で「…」で切る。
    public static func wrappingInsteadOfTruncating(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle, truncatingModes.contains(style.lineBreakMode) else { return }
            style.lineBreakMode = .byWordWrapping
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    /// 行の寄せ方を、UILabelが描くのと同じにした文字列。
    /// 寄せ方が「自然」のとき、UILabelは画面の向き（日本語なら左から右）で寄せるが、TextKit 2は段落の文字の向きで寄せ、
    /// ヘブライ語やアラビア語の段落を右に寄せる。そのままだと行の置き場所がまるごとずれ、リンクを外すため、画面の向きに合わせて決めておく。
    public static func aligned(_ text: NSAttributedString, direction: UIUserInterfaceLayoutDirection) -> NSAttributedString {
        let resolved: NSTextAlignment = direction == .rightToLeft ? .right : .left
        let result = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            guard style.alignment == .natural else { return }
            style.alignment = resolved
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }
}

/// メインスレッドの外で先に並べた、ラベルの文字列の並び。並べ終えたらメインスレッドへ渡し、以後はメインスレッドだけが触る。
/// 置く側は、並べた文字列（`source`）をそのままラベルに入れ、`TextKitLabel.usePreparedLayout`で渡す。
public final class PreparedTextLayout {
    public let source: NSAttributedString
    public let style: TextKitLabelLayout.Style
    public let width: CGFloat
    /// 行数ごとの並びと大きさ。0は行数を限らない並び。
    private let entries: [Int: (layout: TextLayout, metrics: TextKitLabelLayout.Metrics)]

    /// `source`を`width`の幅に、行数を限らずに並べる。`truncatedLineLimit`が、並べた行数から切って出す行数を返せば、その行数でも並べる。
    public init(source: NSAttributedString, style: TextKitLabelLayout.Style, width: CGFloat, truncatedLineLimit: (_ lineCount: Int) -> Int?) {
        self.source = source
        self.style = style
        self.width = width
        let filled = TextKitLabelLayout.filled(source, style: style)
        var entries: [Int: (layout: TextLayout, metrics: TextKitLabelLayout.Metrics)] = [:]
        let full = TextKitLabelLayout.layout(of: filled, width: width, maximumLines: 0, style: style)
        if let metrics = TextKitLabelLayout.metrics(of: full, displayScale: style.displayScale) {
            entries[0] = (full, metrics)
            if let lines = truncatedLineLimit(metrics.lineCount) {
                let truncated = TextKitLabelLayout.layout(of: filled, width: width, maximumLines: lines, style: style)
                if let truncatedMetrics = TextKitLabelLayout.metrics(of: truncated, displayScale: style.displayScale) {
                    entries[lines] = (truncated, truncatedMetrics)
                }
            }
        }
        self.entries = entries
    }

    /// `width`の幅に`maximumLines`行まで並べた結果。並べていなければnil。
    public func entry(width: CGFloat, maximumLines: Int) -> (layout: TextLayout, metrics: TextKitLabelLayout.Metrics)? {
        guard width == self.width else { return nil }
        return entries[maximumLines]
    }
}

/// `TextKitLabelLayout`で文字を並べた結果と、並べたときの条件。
public struct TextLayout {
    public let width: CGFloat
    public let direction: UIUserInterfaceLayoutDirection
    public let contentStorage: NSTextContentStorage
    public let layoutManager: NSTextLayoutManager
    /// 場所取りに置き換えた文字列（`TextKitLabelLayout.placingOverlaidGlyphs(_:)`）。置き換えた文字がなければnil。
    /// 描くときに、置き換えた文字のない文字列では、重ねて描く字形を探さずに済ませるのに使う。
    public var overlaidText: NSAttributedString? = nil

    public init(
        width: CGFloat, direction: UIUserInterfaceLayoutDirection, contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager,
        overlaidText: NSAttributedString? = nil
    ) {
        self.width = width
        self.direction = direction
        self.contentStorage = contentStorage
        self.layoutManager = layoutManager
        self.overlaidText = overlaidText
    }
}

/// 場所取りの上に重ねて描く字形（`TextKitLabelLayout.placingOverlaidGlyphs(_:)`）。置き換える前の文字と書体と色で描く。
public struct OverlaidGlyph: Hashable, Sendable {
    public let text: String
    public let font: UIFont
    public let color: UIColor?
    public let baselineOffset: CGFloat

    /// `origin`（ベースラインの左端）に描く。`context`は、UIKitと同じく下向きが正の座標。
    public func draw(atBaseline origin: CGPoint, in context: CGContext) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color.cgColor }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y - baselineOffset)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

extension NSAttributedString.Key {
    /// TextKit 2で描くときに、場所取りの上に重ねて描く文字。値は、場所取りの文字の書体（`UIFont`）。
    /// 行の高さを、書体のascenderとdescenderではなく、描く字形の枠で決めたい文字に付ける（`TextKitLabelLayout.placingOverlaidGlyphs(_:)`）。
    /// UILabelで描くときは、ふつうの文字として描く。
    public static let overlaidGlyphs = NSAttributedString.Key("TextKit2Label.overlaidGlyphs")
    /// 場所取りに置き換えた文字の、重ねて描く字形（`OverlaidGlyph`）。並べるときに付け、置く側は付けない。
    public static let overlaidGlyph = NSAttributedString.Key("TextKit2Label.overlaidGlyph")
    /// 場所取りに置き換えた書記素クラスタの、2文字目からの幅のない文字。並べるときに付け、置く側は付けない。
    public static let overlaidGlyphFiller = NSAttributedString.Key("TextKit2Label.overlaidGlyphFiller")
}
