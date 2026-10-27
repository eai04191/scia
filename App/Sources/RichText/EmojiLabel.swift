import CoreText
import SciaCore
import UIKit

/// RichTextRendererで描いた文字列を出すラベルの土台。文字の中のアニメーションするカスタム絵文字を動かす。
/// UILabelは文字の配置を公開しないため、同じ文字列と幅でTextKit 2に並べ直して、絵文字の位置を求める。
/// TextKit 2の行の位置は、UILabelが描いた位置と一致することを確かめている。
/// ラベルは文字の高さに合わせて置くため、UILabelが余った高さで文字を縦に中央へ寄せる分はずれとして扱わない。
///
/// 動かすのは、ラベルの中に収まっている絵文字だけにする。切られて見えない行にある絵文字と、行末で切られてはみ出す絵文字は、文字の中の静止画のまま描く。
/// 「…」で切るラベルが実際に切られているときは、最後の行のうち、「…」に置き換わるかもしれない絵文字も静止画にする。UILabelが末尾を「…」に置き換えた位置は、
/// TextKit 2の並びからは分からず、動く層だけが「…」の上に残るおそれがあるため。UILabelは折り返したあとで最後の行の末尾だけを置き換えるので、
/// 末尾で切るときは、絵文字の右端に「…」の幅を足しても行に収まる絵文字は、並べた位置のまま残る。それより行末に近い絵文字だけを止める。
/// 先頭や中ほどで切るとき、右から左に書く文字を含む段落、左寄せでないときは、置き換えで行の中の位置が動くので、最後の行の絵文字をすべて止める。
class EmojiLabel: UILabel {
    /// アニメーションするカスタム絵文字を動かすときに、アニメーション版を読み込むストア。nilなら、絵文字は静止画のまま描く。
    var emojiImages: EmojiImageStore? {
        didSet {
            guard emojiImages !== oldValue else { return }
            animatedEmojis?.removeLayers()
            animatedEmojis = emojiImages.map { store in
                AnimatedEmojiOverlay(store: store) { [weak self] in self?.applyAnimatedEmojis() }
            }
            if animatedEmojis == nil, showsReplacedText {
                super.attributedText = sourceText
                layoutCache = nil
                showsReplacedText = false
            }
            applyAnimatedEmojis()
        }
    }

    override var attributedText: NSAttributedString? {
        didSet {
            layoutCache = nil
            truncationCache = nil
            sourceText = attributedText
            hasCustomEmoji = attributedText.map(Self.containsCustomEmoji) ?? false
            showsReplacedText = false
            stillEmojiIndices = []
            applyAnimatedEmojis()
        }
    }

    override var text: String? {
        didSet {
            layoutCache = nil
            truncationCache = nil
            sourceText = nil
            hasCustomEmoji = false
            showsReplacedText = false
            stillEmojiIndices = []
            applyAnimatedEmojis()
        }
    }

    override var numberOfLines: Int {
        didSet {
            layoutCache = nil
            truncationCache = nil
            setNeedsLayout()
        }
    }

    override var lineBreakMode: NSLineBreakMode {
        didSet {
            layoutCache = nil
            truncationCache = nil
            setNeedsLayout()
        }
    }

    /// 置く側が渡した文字列。アニメーションする絵文字を透明な画像に差し替える前のもの。
    private var sourceText: NSAttributedString?

    /// 置く側が渡した文字列。描いている`attributedText`は、アニメーションする絵文字を透明な画像に差し替えたものなので、
    /// 色や下線を変えて書き戻すときはこちらを読む。差し替えたものを書き戻すと、動かすのをやめたときに静止画に戻せなくなる。
    var originalAttributedText: NSAttributedString? {
        sourceText ?? attributedText
    }
    /// `sourceText`にカスタム絵文字がある。なければ、並べ直さずに済ませる。
    private var hasCustomEmoji = false
    /// 描いているのが、絵文字を差し替えた文字列。
    private var showsReplacedText = false
    /// 動かさず、文字の中の静止画のまま描く絵文字の位置。並べてみるまで分からないため、`layoutSubviews`で決める。
    private var stillEmojiIndices: Set<Int> = []
    private var animatedEmojis: AnimatedEmojiOverlay?
    /// 並べ直した結果。リンクを探すたびや、並べ直すたびに作らないよう、文字列と幅が変わるまで使い回す。
    private var layoutCache: TextLayout?
    /// 「…」で切られているかを、調べたときの幅とともに持つ。
    private var truncationCache: (width: CGFloat, isTruncated: Bool)?

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutAnimatedEmojis()
    }

    /// 置く側が渡した文字列から、アニメーション版が届いている絵文字を透明な画像に差し替えて描き直す。
    /// 差し替えた画像は元と同じ大きさなので、ラベルの大きさは変わらない。
    private func applyAnimatedEmojis() {
        guard let animatedEmojis else { return }
        let shown = animatedEmojis.prepare(sourceText, keepingStill: stillEmojiIndices)
        let replaces = shown !== sourceText
        // 差し替えないときは、置く側が渡した文字列をすでに描いている。前に差し替えていたら、元に戻す。
        if replaces || showsReplacedText {
            super.attributedText = shown
            layoutCache = nil
        }
        showsReplacedText = replaces
        setNeedsLayout()
    }

    /// 動かす絵文字の層を、文字の中の絵文字の位置に合わせる。
    private func layoutAnimatedEmojis() {
        guard let animatedEmojis else { return }
        guard let attributedText, hasCustomEmoji, bounds.width > 0 else {
            animatedEmojis.layout(in: layer, frames: [])
            return
        }
        let layout = textLayout(of: attributedText)
        // 差し替える前の文字列のすべての絵文字で決めるので、決めた結果で差し替え直しても変わらず、行き来しない。
        let stillIndices = stillEmojiIndices(in: layout)
        if stillIndices != stillEmojiIndices {
            stillEmojiIndices = stillIndices
            applyAnimatedEmojis()
            return
        }
        animatedEmojis.layout(in: layer, frames: animatedEmojis.entries.map { attachmentFrame(at: $0.index, in: layout) })
    }

    private static func containsCustomEmoji(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.customEmoji, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// 動かさない絵文字の位置。ラベルに収まらない絵文字と、「…」で切られているときに、最後の行で「…」に置き換わるかもしれない絵文字。
    private func stillEmojiIndices(in layout: TextLayout) -> Set<Int> {
        guard let sourceText else { return [] }
        let visible = bounds.insetBy(dx: -1, dy: -1)
        var indices: Set<Int> = []
        sourceText.enumerateAttribute(.customEmoji, in: NSRange(location: 0, length: sourceText.length)) { value, range, _ in
            guard value != nil else { return }
            for index in range.location..<NSMaxRange(range) {
                guard let frame = attachmentFrame(at: index, in: layout), visible.contains(frame) else {
                    indices.insert(index)
                    continue
                }
                if mayBeReplacedByEllipsis(frame, at: index, in: layout) {
                    indices.insert(index)
                }
            }
        }
        return indices
    }

    /// `index`の文字（並べた枠は`frame`）が、UILabelが末尾を「…」に置き換えた部分に入るかもしれないか。
    /// 「…」で切られていないときと、見える最後の行より上の文字はfalse。置き換えた部分の文字は描かれないので、動かす層を重ねない。
    /// 並べ直しでも最後の行を「…」で切るので、置き換わった文字はふつう並びから外れるが、絵文字の層が「…」の上に残ると目立つため、位置の分からない行はまとめて止める。
    /// リンクの当たり判定には使わない。位置の分からない行で、見えているリンクまで押せなくなるため。
    private func mayBeReplacedByEllipsis(_ frame: CGRect, at index: Int, in layout: TextLayout) -> Bool {
        guard let attributedText, isTruncatedWithEllipsis(), let lastLineMinY = lastVisibleLineMinY(in: layout), frame.midY >= lastLineMinY else { return false }
        return !staysBeforeEllipsis(frame, at: index, in: attributedText)
    }

    /// 最後の行の`index`の文字が、末尾を「…」に置き換えても、並べた位置のまま残るか。
    /// 末尾で切る左寄せの左から右へ書く行で、文字の右端に「…」の幅を足しても行に収まるとき。
    private func staysBeforeEllipsis(_ frame: CGRect, at index: Int, in text: NSAttributedString) -> Bool {
        guard effectiveUserInterfaceLayoutDirection == .leftToRight, !Self.containsRightToLeft(paragraphAt: index, in: text) else { return false }
        let style = text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        let mode = style?.lineBreakMode ?? lineBreakMode
        let alignment = style?.alignment ?? textAlignment
        guard mode == .byTruncatingTail, alignment == .left || alignment == .natural else { return false }
        return frame.maxX + ellipsisWidth(in: text) <= bounds.width
    }

    /// `index`を含む段落に、右から左へ書く文字があるか。画面が左から右でも、アラビア語やヘブライ語の段落は右から左に並び、「…」は左の端に入る。
    private static func containsRightToLeft(paragraphAt index: Int, in text: NSAttributedString) -> Bool {
        let range = (text.string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
        let line = CTLineCreateWithAttributedString(text.attributedSubstring(from: range))
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        return runs.contains { CTRunGetStatus($0).contains(.rightToLeft) }
    }

    /// 「…」の幅。UILabelは「…」を、置き換えた位置の文字の大きさで描くが、その位置は分からないので、文字列の中でいちばん大きい文字で測る。
    private func ellipsisWidth(in text: NSAttributedString) -> CGFloat {
        var fonts = [font].compactMap { $0 }
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let font = value as? UIFont { fonts.append(font) }
        }
        return fonts.map { ("…" as NSString).size(withAttributes: [.font: $0]).width }.max() ?? 0
    }

    /// 行数を限っていて、文字列がその行数に収まらず、末尾を「…」で切っているか。
    private func isTruncatedWithEllipsis() -> Bool {
        guard numberOfLines > 0, let sourceText, usesEllipsis(sourceText) else { return false }
        if let truncationCache, truncationCache.width == bounds.width {
            return truncationCache.isTruncated
        }
        let isTruncated = lineCount(of: sourceText) > numberOfLines
        truncationCache = (bounds.width, isTruncated)
        return isTruncated
    }

    /// ラベルか文字列の段落が、はみ出す分を「…」で切る。
    private func usesEllipsis(_ text: NSAttributedString) -> Bool {
        if Self.truncatingModes.contains(lineBreakMode) { return true }
        var found = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, Self.truncatingModes.contains(style.lineBreakMode) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// 行数を限らずに、ラベルの幅で並べたときの行数。
    private func lineCount(of text: NSAttributedString) -> Int {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: 0))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.attributedString = Self.wrappingInsteadOfTruncating(text)
        var count = 0
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            count += fragment.textLineFragments.count
            return true
        }
        return count
    }

    /// `index`の文字に埋め込んだ画像を描く枠。ラベルの座標で返す。並べた範囲の外ならnil。
    private func attachmentFrame(at index: Int, in layout: TextLayout) -> CGRect? {
        let contentStorage = layout.contentStorage
        guard let location = contentStorage.location(contentStorage.documentRange.location, offsetBy: index),
              let fragment = layout.layoutManager.textLayoutFragment(for: location)
        else { return nil }
        let frame = fragment.frameForTextAttachment(at: location)
        guard !frame.isEmpty else { return nil }
        return frame.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
    }

    /// ラベルの中に見える最後の行の上端。ラベルの座標で返す。
    private func lastVisibleLineMinY(in layout: TextLayout) -> CGFloat? {
        var result: CGFloat?
        layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                let minY = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
                guard minY < bounds.maxY else { return false }
                result = minY
            }
            return true
        }
        return result
    }

    /// `attributedText`をラベルと同じ幅で並べた結果。幅か画面の向きが変わったときだけ並べ直す。
    final func textLayout(of attributedText: NSAttributedString) -> TextLayout {
        let direction = effectiveUserInterfaceLayoutDirection
        if let layoutCache, layoutCache.width == bounds.width, layoutCache.direction == direction {
            return layoutCache
        }
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        // 高さは限らない。最後の行の下の行間まで数えるとラベルより高くなり、ラベルの高さで切ると最後の行が並ばない。
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: 0))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        // 段落は折り返しにして、コンテナで最後の行だけを「…」で切る。最後の行に入りきらない単語も、UILabelと同じく「…」の前まで途中を並べる。
        container.lineBreakMode = truncationMode(of: attributedText) ?? lineBreakMode
        layoutManager.textContainer = container
        contentStorage.attributedString = Self.wrappingInsteadOfTruncating(alignedLikeLabel(attributedText))
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let layout = TextLayout(width: bounds.width, direction: direction, contentStorage: contentStorage, layoutManager: layoutManager)
        layoutCache = layout
        return layout
    }

    /// カスタム絵文字を描く枠。ラベルの座標で返す。「投稿の見た目」のプレビューで、絵文字の場所を示すのに使う。
    final func previewCustomEmojiFrames() -> [CGRect] {
        guard let attributedText, attributedText.length > 0 else { return [] }
        let layout = textLayout(of: attributedText)
        var frames: [CGRect] = []
        attributedText.enumerateAttribute(.customEmoji, in: NSRange(location: 0, length: attributedText.length)) { value, range, _ in
            guard value != nil, let frame = attachmentFrame(at: range.location, in: layout) else { return }
            frames.append(frame)
        }
        return frames
    }

    /// 並べた行ごとの、行の枠と、段落の最初の行か、行の字下げ。ラベルの座標で返す。
    /// 「投稿の見た目」のプレビューで、行間、段落のあいだ、字下げの場所を示すのに使う。
    final func previewLines() -> [(frame: CGRect, startsParagraph: Bool, indent: CGFloat)] {
        guard let attributedText, attributedText.length > 0 else { return [] }
        let layout = textLayout(of: attributedText)
        var lines: [(frame: CGRect, startsParagraph: Bool, indent: CGFloat)] = []
        layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            for (index, line) in fragment.textLineFragments.enumerated() {
                let style = line.attributedString.length > 0
                    ? line.attributedString.attribute(.paragraphStyle, at: line.characterRange.location, effectiveRange: nil) as? NSParagraphStyle
                    : nil
                let indent = index == 0 ? style?.firstLineHeadIndent ?? 0 : style?.headIndent ?? 0
                let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
                lines.append((bounds, index == 0, indent))
            }
            return true
        }
        return lines
    }

    private static let truncatingModes: [NSLineBreakMode] = [.byTruncatingTail, .byTruncatingHead, .byTruncatingMiddle]

    /// 段落の「…」で切る設定を、単語で折り返す設定に替えた文字列。
    /// UILabelは、行数を限ったときも折り返してから最後の行だけを「…」で切るが、TextKit 2は「…」で切る段落を折り返さずに1行に並べる。
    /// そのまま並べると、2行目より後の文字の位置がUILabelの描画と合わないため、段落は折り返して並べ、最後の行はコンテナの設定で「…」で切る。
    /// ラベルか段落の「…」で切る設定。UILabelは文字列を入れると段落の設定で自分の`lineBreakMode`を上書きするので、段落の設定を先に見る。
    private func truncationMode(of text: NSAttributedString) -> NSLineBreakMode? {
        var mode: NSLineBreakMode?
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, Self.truncatingModes.contains(style.lineBreakMode) {
                mode = style.lineBreakMode
                stop.pointee = true
            }
        }
        return mode ?? (Self.truncatingModes.contains(lineBreakMode) ? lineBreakMode : nil)
    }

    private static func wrappingInsteadOfTruncating(_ text: NSAttributedString) -> NSAttributedString {
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
    private func alignedLikeLabel(_ text: NSAttributedString) -> NSAttributedString {
        let resolved: NSTextAlignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
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

    /// ラベルの座標`point`にある文字の位置。文字の上でなければnil。
    final func characterIndex(at point: CGPoint) -> Int? {
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
    final func characterFrame(
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

/// `EmojiLabel`の文字を並べた結果と、並べたときの条件。
struct TextLayout {
    let width: CGFloat
    let direction: UIUserInterfaceLayoutDirection
    let contentStorage: NSTextContentStorage
    let layoutManager: NSTextLayoutManager
}
