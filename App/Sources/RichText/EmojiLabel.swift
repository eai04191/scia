import SciaCore
import UIKit

/// RichTextRendererで描いた文字列を出すラベルの土台。文字の中のアニメーションするカスタム絵文字を動かす。
/// UILabelは文字の配置を公開しないため、同じ文字列と幅でTextKit 2に並べ直して、絵文字の位置を求める。
/// TextKit 2の行の位置は、UILabelが描いた位置と一致することを確かめている。
/// ラベルは文字の高さに合わせて置くため、UILabelが余った高さで文字を縦に中央へ寄せる分はずれとして扱わない。
///
/// 行数を限ったラベルでは、最後の行の末尾をUILabelが「…」に置き換えることがあり、置き換えた絵文字の位置はTextKit 2の並びからは分からない。
/// 動く層だけが「…」の上に残らないよう、最後の行の絵文字は動かさず、文字の中の静止画のまま描く。切られていないときも動かないが、試作では許す。
class EmojiLabel: UILabel {
    /// アニメーションするカスタム絵文字を動かすときに、アニメーション版を読む置き場。nilなら、絵文字は静止画のまま描く。
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
        }
    }

    override var lineBreakMode: NSLineBreakMode {
        didSet {
            layoutCache = nil
        }
    }

    /// 置く側が渡した文字列。アニメーションする絵文字を透明な画像に差し替える前のもの。
    private var sourceText: NSAttributedString?
    /// `sourceText`にカスタム絵文字がある。なければ、並べ直さずに済ませる。
    private var hasCustomEmoji = false
    /// 描いているのが、絵文字を差し替えた文字列。
    private var showsReplacedText = false
    /// 動かさず、文字の中の静止画のまま描く絵文字の位置。並べてみるまで分からないため、`layoutSubviews`で決める。
    private var stillEmojiIndices: Set<Int> = []
    private var animatedEmojis: AnimatedEmojiOverlay?
    /// 並べ直した結果。リンクを探すたびや、並べ直すたびに作らないよう、文字列と幅が変わるまで使い回す。
    private var layoutCache: TextLayout?

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
        let frames = animatedEmojis.entries.map { entry -> CGRect? in
            guard let frame = attachmentFrame(at: entry.index, in: layout), frame.maxY <= bounds.maxY + 1 else { return nil }
            return frame
        }
        animatedEmojis.layout(in: layer, frames: frames)
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

    /// 動かさない絵文字の位置。行数を限ったラベルの、見える最後の行と、それより下にある絵文字。
    private func stillEmojiIndices(in layout: TextLayout) -> Set<Int> {
        guard numberOfLines > 0, let sourceText, let lastLineMinY = lastVisibleLineMinY(in: layout) else { return [] }
        var indices: Set<Int> = []
        sourceText.enumerateAttribute(.customEmoji, in: NSRange(location: 0, length: sourceText.length)) { value, range, _ in
            guard value != nil else { return }
            for index in range.location..<NSMaxRange(range) {
                guard let frame = attachmentFrame(at: index, in: layout) else {
                    // 並べた範囲の外（切られて見えない行）にある。
                    indices.insert(index)
                    continue
                }
                if frame.midY >= lastLineMinY { indices.insert(index) }
            }
        }
        return indices
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
        container.lineBreakMode = lineBreakMode
        layoutManager.textContainer = container
        contentStorage.attributedString = alignedLikeLabel(attributedText)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let layout = TextLayout(width: bounds.width, direction: direction, contentStorage: contentStorage, layoutManager: layoutManager)
        layoutCache = layout
        return layout
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

    /// `index`の文字が描かれる枠。ラベルの座標で返す。
    final func characterFrame(at index: Int, in contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) -> CGRect? {
        guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: index),
              let end = contentStorage.location(start, offsetBy: 1),
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
