import CoreText
import SciaCore
import UIKit

/// RichTextRendererで描いた文字列を出すラベルの土台。文字の中のアニメーションするカスタム絵文字を動かす。
/// UILabelは文字の配置を公開しないため、同じ文字列と幅でTextKit 2に並べ直して、絵文字の位置を求める。
/// TextKit 2の行の位置は、UILabelが描いた位置と一致することを確かめている。
/// ラベルは文字の高さに合わせて置くため、UILabelが余った高さで文字を縦に中央へ寄せる分はずれとして扱わない。
///
/// 動かすのは、ラベルの中に収まっている絵文字だけにする。切られて見えない行にある絵文字と、行末で切られてはみ出す絵文字、薄くしている範囲（`obscuredTextRect`）の絵文字は、文字の中の静止画のまま描く。
/// 「…」で切るラベルが実際に切られているときは、最後の行のうち、「…」に置き換わるかもしれない絵文字も静止画にする。UILabelが末尾を「…」に置き換えた位置は、
/// TextKit 2の並びからは分からず、動く層だけが「…」の上に残るおそれがあるため。UILabelは折り返したあとで最後の行の末尾だけを置き換えるので、
/// 末尾で切るときは、絵文字の右端に「…」の幅を足しても行に収まる絵文字は、並べた位置のまま残る。それより行末に近い絵文字だけを止める。
/// 先頭や中ほどで切るとき、右から左に書く文字を含む段落、左寄せでないときは、置き換えで行の中の位置が動くので、最後の行の絵文字をすべて止める。
class EmojiLabel: UILabel {
    /// アニメーションするカスタム絵文字を動かすときに、アニメーション版を読み込むストア。nilなら、絵文字は静止画のまま描く。
    var emojiImages: EmojiImageStore<UIImage>? {
        didSet {
            guard emojiImages !== oldValue else { return }
            animatedEmojis?.removeLayers()
            animatedEmojis = emojiImages.map { store in
                AnimatedEmojiOverlay(store: store) { [weak self] in self?.applyAnimatedEmojis() }
            }
            if animatedEmojis == nil, showsReplacedText {
                setShownText(sourceText)
                layoutCache = nil
                showsReplacedText = false
            }
            applyAnimatedEmojis()
        }
    }

    /// 置く側が前に渡したものと中身が同じなら、入れ替えない。行を組み直すたびに文字列は作り直されるが、
    /// 入れ替えるとUILabelがベースラインや大きさを測り直し、長い本文では組み直しの大半をそこに使うため。
    override var attributedText: NSAttributedString? {
        get { drawsWithTextKit ? textKitText : super.attributedText }
        set {
            if let assignedText, Self.hasSameContent(assignedText, newValue) {
                // 入れ替えていれば、そこで読めなかったアニメーション版を読み直していた。入れ替えなくても読み直す。
                animatedEmojis?.reloadMissingAnimations()
                return
            }
            // UILabelは受け取った文字列を写し替えて持ち、絵文字の画像も同じものではなくなるため、置く側が渡したもの同士で比べる。
            let filled = Self.filledEmojiIndices(from: assignedText, to: newValue)
            if !filled.isEmpty {
                prepareEmojiArrival(filling: filled)
            } else if assignedText?.string != newValue?.string {
                // 絵文字を入れている途中に、使い回された行で別の文字列に替わったら、前の文字列の像を重ねない。
                cancelEmojiArrival()
            }
            assignedText = newValue
            preparedLayout = nil
            // 測った結果は、文字列を入れる前に捨てる。UILabelは文字列を入れる中で大きさを測り直して覚えるため、
            // あとで捨てると、使い回したラベルが前の文字列で測った大きさのままになる。
            layoutCache = nil
            truncationCache = nil
            attributedTextWillChange()
            setShownText(newValue)
            sourceText = attributedText
            hasCustomEmoji = sourceText.map(Self.containsCustomEmoji) ?? false
            showsReplacedText = false
            stillEmojiIndices = []
            applyAnimatedEmojis()
        }
    }

    /// 置く側が中身の違う文字列を入れる前に呼ぶ。文字列から測った結果を持つ派生のラベルが、ここで捨てる。
    /// UILabelは文字列を入れる中で大きさを測り直して覚えるため、入れたあとに捨てると、前の文字列で測った結果を使われる。
    func attributedTextWillChange() {}

    /// 2つの文字列の、描いたときの中身が同じか。文字と属性を比べ、カスタム絵文字の添付は、画像が同じものかと大きさで比べる。
    /// 添付は描き直すたびに新しく作られ、`NSTextAttachment`同士はものが同じでないと等しくならないため。
    static func hasSameContent(_ old: NSAttributedString?, _ new: NSAttributedString?) -> Bool {
        guard let old, let new else { return old == nil && new == nil }
        guard old !== new else { return true }
        guard old.length == new.length, old.string == new.string else { return false }
        var isSame = true
        old.enumerateAttributes(in: NSRange(location: 0, length: old.length)) { attributes, range, stop in
            var newRange = NSRange()
            let newAttributes = new.attributes(at: range.location, longestEffectiveRange: &newRange, in: range)
            guard newRange == range, attributes.count == newAttributes.count, attributes.allSatisfy({ key, value in
                newAttributes[key].map { Self.isSameAttribute(value, $0) } ?? false
            }) else {
                isSame = false
                stop.pointee = true
                return
            }
        }
        return isSame
    }

    private static func isSameAttribute(_ old: Any, _ new: Any) -> Bool {
        if let old = old as? NSTextAttachment, let new = new as? NSTextAttachment {
            return old === new || (old.image === new.image && old.bounds == new.bounds)
        }
        return (old as AnyObject).isEqual(new as AnyObject)
    }

    override var text: String? {
        willSet {
            layoutCache = nil
            attributedTextWillChange()
        }
        didSet {
            assignedText = nil
            preparedLayout = nil
            cancelEmojiArrival()
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
            preparedLayout = nil
            layoutCache = nil
            truncationCache = nil
            setNeedsLayout()
        }
    }

    /// カスタム絵文字の画像が届いて、空けていた場所に入るときの動きの時間。0なら切り替える。
    var emojiArrivalDuration: () -> TimeInterval = { AppDependencies.tuning.value(of: TuningCatalog.customEmojiArrivalDuration) }

    /// 同じ文字列のまま、読み込み中で空けていたカスタム絵文字の場所に画像が入った位置。入っていなければ空。
    static func filledEmojiIndices(from old: NSAttributedString?, to new: NSAttributedString?) -> Set<Int> {
        guard let old, let new, old.length == new.length, old.string == new.string else { return [] }
        var filled: Set<Int> = []
        old.enumerateAttribute(.attachment, in: NSRange(location: 0, length: old.length)) { value, range, _ in
            guard (value as? NSTextAttachment)?.image === RichTextRenderer.emojiPlaceholder,
                  let image = (new.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment)?.image,
                  image !== RichTextRenderer.emojiPlaceholder
            else { return }
            filled.insert(range.location)
        }
        return filled
    }

    /// 絵文字の画像が入るときの動き。文字列を入れ替える前に前の並びを測っておき、並べ終えた`layoutSubviews`で動かし始める。
    private(set) var emojiArrival: EmojiArrivalTransition?
    /// 前の並びを測り、まだ動かし始めていない。
    private var pendingEmojiArrival = false

    /// 文字列を入れ替える前に、動き始めるときの文字の見え方を測る。動いている途中なら、いま見えている位置と濃さから動かし直す。
    private func prepareEmojiArrival(filling filled: Set<Int>) {
        let running = emojiArrival?.isRunning == true ? emojiArrival : nil
        let duration = emojiArrivalDuration()
        guard duration > 0, window != nil, bounds.width > 0, let shown = attributedText else {
            cancelEmojiArrival()
            return
        }
        // 視差効果を減らす設定では、文字を動かさず、前の描画から薄くして入れ替える。
        guard !UIAccessibility.isReduceMotionEnabled else {
            cancelEmojiArrival()
            let transition = CATransition()
            transition.type = .fade
            transition.duration = duration
            layer.add(transition, forKey: kCATransition)
            return
        }
        let start = running?.currentPlacements(filling: filled) ?? EmojiArrivalTransition.placements(of: shown, in: self, filling: filled)
        let startBars = running?.currentBars() ?? quoteBarFrames()
        // 前の動きの層は、次の動きを始めるまで残す。同じ描き直しの中で入れ替わるので、そのあいだのコマは描かれない。
        let previous = emojiArrival
        emojiArrival = EmojiArrivalTransition(label: self, start: start, startBars: startBars, duration: duration)
        previous?.finish()
        pendingEmojiArrival = true
        setNeedsLayout()
    }

    private func cancelEmojiArrival() {
        pendingEmojiArrival = false
        emojiArrival?.finish()
        emojiArrival = nil
    }

    /// 置く側が最後に渡した文字列そのもの。絵文字の画像が届いたかを見分けるのに使う。
    private var assignedText: NSAttributedString?

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
    private var layoutCache: TextLayout? {
        didSet {
            // 並べ直すときは、測った大きさも捨てる。並べ直すのは、文字列や行数、改行の仕方が変わったとき。
            if layoutCache == nil { textKitMetrics = [:] }
        }
    }
    /// 「…」で切られているかを、調べたときの幅とともに持つ。
    private var truncationCache: (width: CGFloat, isTruncated: Bool)?
    /// 描いた文字を薄くしたり消したりしている範囲。ラベルの座標。ここにかかる絵文字は、動かす層を重ねず、文字の中の静止画のまま描く。
    /// 層は文字と一緒に薄くならないため。`layoutSubviews`より前に決める。
    var obscuredTextRect: CGRect? {
        didSet {
            guard obscuredTextRect != oldValue else { return }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutAnimatedEmojis()
        if pendingEmojiArrival, let attributedText {
            pendingEmojiArrival = false
            emojiArrival?.start(newText: attributedText)
        } else if emojiArrival?.isRunning == true {
            emojiArrival?.hideLabelLayers()
        }
    }

    /// 置く側が渡した文字列から、アニメーション版が届いている絵文字を透明な画像に差し替えて描き直す。
    /// 差し替えた画像は元と同じ大きさなので、ラベルの大きさは変わらない。
    private func applyAnimatedEmojis() {
        guard let animatedEmojis else { return }
        let shown = animatedEmojis.prepare(sourceText, keepingStill: stillEmojiIndices, displayScale: traitCollection.displayScale)
        let replaces = shown !== sourceText
        // 差し替えないときは、置く側が渡した文字列をすでに描いている。前に差し替えていたら、元に戻す。
        if replaces || showsReplacedText {
            setShownText(shown)
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
                guard let frame = attachmentFrame(at: index, in: layout), visible.contains(frame), !(obscuredTextRect?.intersects(frame) ?? false) else {
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
        if TextKitLabelLayout.truncatingModes.contains(lineBreakMode) { return true }
        var found = false
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, TextKitLabelLayout.truncatingModes.contains(style.lineBreakMode) {
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
        contentStorage.attributedString = TextKitLabelLayout.wrappingInsteadOfTruncating(text)
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
        // 絵文字を透明な画像に差し替えて描いているときは、先に並べた並びを使わない。先に並べた並びは、差し替える前の画像を描くため。
        let layout = (showsReplacedText ? nil : preparedLayout?.entry(width: bounds.width, maximumLines: numberOfLines)?.layout)
            ?? makeTextLayout(of: attributedText, width: bounds.width, maximumLines: numberOfLines)
        layoutCache = layout
        return layout
    }

    private func makeTextLayout(of attributedText: NSAttributedString, width: CGFloat, maximumLines: Int) -> TextLayout {
        TextKitLabelLayout.layout(of: attributedText, width: width, maximumLines: maximumLines, style: textKitStyle)
    }

    /// TextKit 2で並べるときに使う、ラベルの値。
    final var textKitStyle: TextKitLabelLayout.Style {
        TextKitLabelLayout.Style(
            font: font,
            textColor: textColor,
            lineBreakMode: lineBreakMode,
            direction: effectiveUserInterfaceLayoutDirection,
            displayScale: traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        )
    }

    /// メインスレッドの外で先に並べた結果。置く側が渡した文字列と、ラベルの値が同じときだけ持ち、文字列が替わったら捨てる。
    private var preparedLayout: PreparedTextLayout?

    /// 先に並べた結果を、今の文字列の並びとして使う。文字列を入れたあとに渡す。
    /// 並べた文字列が今の文字列と同じものでないか、並べたときのラベルの値（書体や色、行の切り方、文字の向き）が今と違えば使わない。
    final func usePreparedLayout(_ prepared: PreparedTextLayout?) {
        guard let prepared, drawsWithTextKit, prepared.source === assignedText, prepared.style == textKitStyle else {
            preparedLayout = nil
            return
        }
        guard prepared !== preparedLayout else { return }
        preparedLayout = prepared
        layoutCache = nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// 先に並べた結果の幅。本文の幅が決まる前に、ベースラインを置くのに使う。先に並べていなければnil。
    final var preparedLayoutWidth: CGFloat? {
        preparedLayout?.width
    }

    /// TextKit 2で描くときの、描いている文字列。UILabelが自分のフォントと色で埋めるのと同じく、フォントと色のない部分を埋めてある。
    /// UILabelには持たせない。UILabelは文字列を入れるたびに、自分で並べ直してベースラインを求めるため。
    private var textKitText: NSAttributedString?

    /// 描いている文字列を替える。TextKit 2で描くときは、UILabelには空白1文字だけを渡す。
    /// 空にするとUILabelが描画を省くため、1文字にする。同じ1文字を渡し直してもUILabelは大きさを測り直さないので、測り直しと描き直しは自分で頼む。
    private func setShownText(_ text: NSAttributedString?) {
        guard drawsWithTextKit else {
            super.attributedText = text
            return
        }
        textKitText = text.map(filledLikeLabel)
        if super.attributedText?.string != Self.textKitPlaceholder {
            super.attributedText = NSAttributedString(string: Self.textKitPlaceholder)
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    private static let textKitPlaceholder = " "

    /// フォントと色のない部分を、ラベルのフォントと色で埋めた文字列。UILabelは渡された文字列をこうして埋めてから並べる。
    private func filledLikeLabel(_ text: NSAttributedString) -> NSAttributedString {
        TextKitLabelLayout.filled(text, style: textKitStyle)
    }

    /// TextKit 2で描くときは、UILabelが持つ空白1文字ではなく、描いている文字列を読み上げる。置く側が決めた文言があれば、そちらを使う。
    override var accessibilityLabel: String? {
        get {
            let label = super.accessibilityLabel
            return drawsWithTextKit && label == Self.textKitPlaceholder ? textKitText?.string : label
        }
        set { super.accessibilityLabel = newValue }
    }

    /// UILabelではなく、TextKit 2で並べて描く。大きさも、位置を読むのと同じ並べ方で測る。
    /// UILabelは端末で長い段落の改行位置を段落全体から選び、その計算が重い。行を組み立てるたびに、大きさ、ベースライン、描画で何度も並べるため、
    /// 長い本文の行でフレームが落ちた。TextKit 2はその計算をせず、並べた結果を幅と行数ごとに使い回す。
    /// UILabelのベースライン（`firstBaselineAnchor`など）は、TextKit 2の並びを使わずにUILabelが並べ直して求めるので、置く側は使わず、`textKitBaselines(width:)`で置く。
    var drawsWithTextKit = false {
        didSet {
            guard drawsWithTextKit != oldValue else { return }
            preparedLayout = nil
            // 描いている文字列を、新しい描き方の置き場所へ移す。
            let shown = oldValue ? textKitText : super.attributedText
            if drawsWithTextKit {
                setShownText(shown)
            } else {
                textKitText = nil
                super.attributedText = shown
            }
            layoutCache = nil
            textKitMetrics = [:]
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
        // 先に並べてあれば、その大きさを使う。絵文字を透明な画像に差し替えて描いていても、画像の大きさは同じなので、大きさは変わらない。
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
    final func textKitLineCount(width: CGFloat) -> Int {
        textKitMetrics(width: width, maximumLines: 0)?.lineCount ?? 0
    }

    /// TextKit 2で`width`の幅に今の行数で並べたときの、上端から最初の行のベースラインまでと、最後の行のベースラインから下端まで。
    /// 文字がなければ、どちらも0。
    final func textKitBaselines(width: CGFloat) -> (first: CGFloat, lastFromBottom: CGFloat) {
        textKitMetrics(width: width, maximumLines: numberOfLines).map { ($0.firstBaseline, $0.lastBaselineFromBottom) } ?? (0, 0)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        guard drawsWithTextKit else { return super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines) }
        // 文字がなければ、UILabelに渡した空白1文字ではなく、空の大きさを返す。UILabelも、空の文字列では高さを0にする。
        guard let metrics = textKitMetrics(width: bounds.width, maximumLines: numberOfLines) else {
            return CGRect(origin: bounds.origin, size: .zero)
        }
        return CGRect(origin: bounds.origin, size: CGSize(width: min(metrics.size.width, bounds.width), height: min(metrics.size.height, bounds.height)))
    }

    override func drawText(in rect: CGRect) {
        drawQuoteBars()
        guard drawsWithTextKit, let attributedText, attributedText.length > 0, let context = UIGraphicsGetCurrentContext() else {
            super.drawText(in: rect)
            return
        }
        let layout = textLayout(of: attributedText)
        context.saveGState()
        // 幅より大きい絵文字は、UILabelと同じくラベルの左右の端で切る。切らないと、本文の右に並べた添付ファイルに重なる。
        // 上下は切らない。UILabelも、積み重なる結合文字のように行の外へ伸びる字形は、ラベルの外まで描く。
        context.clip(to: CGRect(x: 0, y: -bounds.height, width: bounds.width, height: bounds.height * 3))
        layout.layoutManager.enumerateTextLayoutFragments(from: layout.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            guard fragment.layoutFragmentFrame.minY < bounds.maxY else { return false }
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return true
        }
        context.restoreGState()
    }

    /// 引用の段落の頭の縦線を、文字の下に描く。文字と同じ描画の中で描くので、文字と一緒に薄くなり、「続きを読む」の手前でも文字と同じく消える。
    private func drawQuoteBars() {
        let frames = quoteBarFrames()
        guard !frames.isEmpty else { return }
        QuoteBars.color.setFill()
        frames.forEach { UIRectFill($0) }
    }

    /// 引用の縦線の枠。ラベルの座標で返す。引用がなければ、文字を並べ直さずに空を返す。
    /// 絵文字が届くときの動きで線を切り出すのと、「投稿の見た目」のプレビューで線の場所を示すのにも使う。
    final func quoteBarFrames() -> [CGRect] {
        guard let attributedText, attributedText.length > 0, bounds.width > 0, QuoteBars.appear(in: attributedText) else { return [] }
        return QuoteBars.frames(in: textLayout(of: attributedText), bounds: bounds)
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

    /// Unicodeの絵文字の枠。ラベルの座標で返す。「投稿の見た目」のプレビューで、絵文字の場所を示すのに使う。
    /// 大きさを変えた印（`scaledUnicodeEmoji`）は1倍では付かないので、描くときと同じ判定で絵文字を探す。
    /// 印から探すと、既定の1倍で絵文字が見つからず、示す範囲が名前の行や本文の全体に替わってしまうため。
    final func previewUnicodeEmojiFrames() -> [CGRect] {
        guard let attributedText, attributedText.length > 0 else { return [] }
        let layout = textLayout(of: attributedText)
        let contentStorage = layout.contentStorage
        let start = contentStorage.documentRange.location
        let string = attributedText.string as NSString
        var frames: [CGRect] = []
        var location = 0
        while location < string.length {
            let cluster = string.rangeOfComposedCharacterSequence(at: location)
            location = NSMaxRange(cluster)
            let attributes = attributedText.attributes(at: cluster.location, effectiveRange: nil)
            guard let font = attributes[.font] as? UIFont,
                  RichTextRenderer.isUnicodeEmoji(string.substring(with: cluster), in: attributes[.scaledUnicodeEmoji] as? UIFont ?? font),
                  let from = contentStorage.location(start, offsetBy: cluster.location),
                  let to = contentStorage.location(start, offsetBy: NSMaxRange(cluster)),
                  let textRange = NSTextRange(location: from, end: to)
            else { continue }
            // 大きさを変えた絵文字を測る`RichTextRenderer.emojiExtent`と同じく、描く絵の枠と下げた量から上下を求める。
            let offset = attributes[.baselineOffset] as? CGFloat ?? 0
            let glyph = EmojiFont.glyphBounds(of: string.substring(with: cluster), in: font)
            let above = glyph.maxY + offset
            let below = -(glyph.minY + offset)
            // 行末の絵文字では、同じ区切りが2回返る。1つの絵文字は行をまたがないので、区切りをまとめて1つの枠にする。
            var emoji: CGRect?
            layout.layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, baseline, _ in
                let segment = CGRect(x: frame.minX, y: frame.minY + baseline - above, width: frame.width, height: above + below)
                emoji = emoji?.union(segment) ?? segment
                return true
            }
            if let emoji {
                frames.append(emoji)
            }
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


    /// TextKit 2で並べたときに、このラベルと同じ位置に文字が並ぶ文字列。「テキストを選択」で、ラベルの代わりに出すテキストビューに渡す。
    /// UILabelが自分のフォントや色で埋めたあとの文字列を使う。段落をつなぐ改行のようにフォントのない部分を、UITextViewは12ptの既定のフォントで並べ、
    /// 空行の高さが変わって下の行がずれるため。
    final var textForTextKit: NSAttributedString? {
        sourceText.map { TextKitLabelLayout.aligned(TextKitLabelLayout.wrappingInsteadOfTruncating($0), direction: effectiveUserInterfaceLayoutDirection) }
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
