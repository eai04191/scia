import CoreText
import SciaCore
import UIKit

/// `EmojiLabel`がTextKit 2で文字を並べる手順。ラベルの値を受け取り、ラベルを使わずに並べる。
/// 一覧の本文をメインスレッドの外で先に並べるときも、ラベルと同じ手順で並べるため、ラベルから分けている。
/// TextKit 2の部品は、同時に1つのスレッドだけが触るなら、メインスレッドの外で使ってよい（NSTextContainer.hの決まり）。
enum TextKitLabelLayout {
    /// 並べ方を決める、ラベルの値。
    struct Style: Equatable, Sendable {
        var font: UIFont?
        var textColor: UIColor?
        var lineBreakMode: NSLineBreakMode
        var direction: UIUserInterfaceLayoutDirection
        var displayScale: CGFloat
    }

    /// 並べた結果の大きさとベースライン。
    struct Metrics: Sendable {
        let size: CGSize
        let lineCount: Int
        /// 上端から最初の行のベースラインまで。
        let firstBaseline: CGFloat
        /// 最後の行のベースラインから下端まで。
        let lastBaselineFromBottom: CGFloat
    }

    /// フォントと色のない部分を、ラベルのフォントと色で埋めた文字列。UILabelは渡された文字列をこうして埋めてから並べる。
    static func filled(_ text: NSAttributedString, style: Style) -> NSAttributedString {
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

    /// `filled(_:style:)`で埋めた文字列を、`width`の幅に`maximumLines`行まで並べる。0なら行数を限らない。
    static func layout(of attributedText: NSAttributedString, width: CGFloat, maximumLines: Int, style: Style) -> TextLayout {
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
        contentStorage.attributedString = wrappingInsteadOfTruncating(aligned(attributedText, direction: style.direction))
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return TextLayout(width: width, direction: style.direction, contentStorage: contentStorage, layoutManager: layoutManager)
    }

    /// 並べた結果の大きさとベースライン。文字がなければnil。
    static func metrics(of layout: TextLayout, displayScale scale: CGFloat) -> Metrics? {
        var lineCount = 0
        var maxX: CGFloat = 0
        var firstBaseline: CGFloat?
        var last: (baseline: CGFloat, line: NSTextLineFragment)?
        layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
                let baseline = bounds.minY + line.glyphOrigin.y
                lineCount += 1
                maxX = max(maxX, bounds.maxX)
                if firstBaseline == nil { firstBaseline = baseline }
                last = (baseline, line)
            }
            return true
        }
        guard let firstBaseline, let last else { return nil }
        let height = ceil((last.baseline + descent(of: last.line)) * scale) / scale
        return Metrics(
            size: CGSize(width: ceil(maxX * scale) / scale, height: height),
            lineCount: lineCount,
            firstBaseline: firstBaseline,
            lastBaselineFromBottom: height - last.baseline
        )
    }

    /// 行のベースラインから下端まで。TextKit 2の行の枠は、下にフォントのleadingを含むが、UILabelは最後の行の下にleadingを足さないため、
    /// 最後の行の下端は、UILabelと同じくCoreTextで測った行の下の長さで決める。
    /// カスタム絵文字の画像がベースラインより下へ伸びる行では、CoreTextの行の下の長さが、画像の下端までになる。
    private static func descent(of line: NSTextLineFragment) -> CGFloat {
        guard line.characterRange.length > 0 else { return line.typographicBounds.height - line.glyphOrigin.y }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(line.attributedString.attributedSubstring(from: line.characterRange)), &ascent, &descent, &leading)
        return descent
    }

    static let truncatingModes: [NSLineBreakMode] = [.byTruncatingTail, .byTruncatingHead, .byTruncatingMiddle]

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
    static func wrappingInsteadOfTruncating(_ text: NSAttributedString) -> NSAttributedString {
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
    static func aligned(_ text: NSAttributedString, direction: UIUserInterfaceLayoutDirection) -> NSAttributedString {
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
/// 置く側は、並べた文字列（`source`）をそのままラベルに入れ、`EmojiLabel.usePreparedLayout`で渡す。
final class PreparedTextLayout {
    /// 並べた文字列。置く側がラベルに入れる文字列と同じもの。
    let source: NSAttributedString
    let style: TextKitLabelLayout.Style
    let width: CGFloat
    /// 行数ごとの並びと大きさ。0は行数を限らない並び。
    private let entries: [Int: (layout: TextLayout, metrics: TextKitLabelLayout.Metrics)]

    /// `source`を`width`の幅に、行数を限らずに並べる。`truncation`で切る行数を超えていれば、切ったときの行数でも並べる。
    init(source: NSAttributedString, style: TextKitLabelLayout.Style, width: CGFloat, truncation: BodyTruncation?) {
        self.source = source
        self.style = style
        self.width = width
        let filled = TextKitLabelLayout.filled(source, style: style)
        var entries: [Int: (layout: TextLayout, metrics: TextKitLabelLayout.Metrics)] = [:]
        let full = TextKitLabelLayout.layout(of: filled, width: width, maximumLines: 0, style: style)
        if let metrics = TextKitLabelLayout.metrics(of: full, displayScale: style.displayScale) {
            entries[0] = (full, metrics)
            if let truncation, metrics.lineCount > truncation.threshold {
                let lines = truncation.lineLimit(exceedsThreshold: true)
                let truncated = TextKitLabelLayout.layout(of: filled, width: width, maximumLines: lines, style: style)
                if let truncatedMetrics = TextKitLabelLayout.metrics(of: truncated, displayScale: style.displayScale) {
                    entries[lines] = (truncated, truncatedMetrics)
                }
            }
        }
        self.entries = entries
    }

    /// `width`の幅に`maximumLines`行まで並べた結果。並べていなければnil。
    func entry(width: CGFloat, maximumLines: Int) -> (layout: TextLayout, metrics: TextKitLabelLayout.Metrics)? {
        guard width == self.width else { return nil }
        return entries[maximumLines]
    }
}
