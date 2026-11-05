import SciaCore
import UIKit

/// 「テキストを選択」で、本文のラベルの代わりに同じ位置に出す、選べるだけのテキストビュー。決まりはdocs/menus.mdの「本文の文字を選ぶ」にある。
/// ラベルと同じ文字の位置になるよう、TextKit 2で並べ、内側の余白と行の左右の余白をなくす。`layoutManager`を読むとTextKit 1に替わるため読まない。
/// 高さはラベルにそろえず、文字に合わせる。ラベルの高さは最後の行の下の行間を数えないので、テキストビューには低く、収まらない最後の行を並べないため。
final class SelectableTextView: UITextView, UITextViewDelegate, @MainActor UIEditMenuInteractionDelegate {
    /// 選択を解いたときと、ほかの部品にフォーカスが移ったときに呼ぶ。
    var onEnd: (() -> Void)?
    /// 押下を受ける高さ。nilなら全体で受ける。文字に合わせて伸ばした最後の行の下の行間が、下の部品（サムネイル、投票など）に重なっても、
    /// その部品へのタップを奪わないよう、差し替えたラベルの高さを返す。
    var touchableHeight: (() -> CGFloat?)?
    /// 最後に触れたタッチの種類。選択が空になったときに、やめるかを決めるのに使う。
    var lastTouchType: UITouch.TouchType?
    /// 引用の縦線。ラベルが文字と一緒に描く線を、文字の後ろの層に同じ位置で引く。差し替えたときに線が消えないようにするため。
    private let quoteBarLayer = CAShapeLayer()
    /// 引いている引用の縦線の枠。
    private(set) var quoteBarFrames: [CGRect] = []
    /// 大きくした絵文字など、場所取りの上に重ねて描く字形（`TextKitLabelLayout.placingOverlaidGlyphs(_:)`）を描くビュー。
    /// UITextViewは場所取りの透明な添付だけを描くため。文字と同じく選択のハイライトの上に描き、場所取りに付いた取り消し線と下線は、字形の上に引き直す。
    private let overlaidGlyphsView = OverlaidGlyphsView()
    private lazy var editMenu: UIEditMenuInteraction = {
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        return interaction
    }()

    /// - Parameter text: 差し替えるラベルの`textForTextKit`。
    init(text: NSAttributedString) {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        // 選んだ文字を持ち出すドラッグは、iPadとして動くMacでは既定で有効になる（iPhoneでは既定で無効）。全体を選んで始めるので、どこを押しても選んだ文字の上になり、
        // マウスでドラッグすると、範囲を選び直す代わりに文字を持ち出すドラッグが始まるため止める。
        textDragInteraction?.isEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        attributedText = text
        delegate = self
        addGestureRecognizer(TouchDownObserver { [weak self] touch in self?.lastTouchType = touch.type })
        layer.insertSublayer(quoteBarLayer, at: 0)
        addSubview(overlaidGlyphsView)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: Self, _) in
            self.setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutQuoteBars()
        layoutOverlaidGlyphs()
    }

    /// 読み上げる文字。場所取りに置き換えた絵文字は、元の絵文字で読む。
    override var accessibilityValue: String? {
        get { TextKitLabelLayout.restoringOverlaidGlyphs(attributedText) }
        set { super.accessibilityValue = newValue }
    }

    /// 重ねて描く字形の位置（ベースラインの左端）。自分の座標で返す。
    var overlaidGlyphOrigins: [CGPoint] {
        overlaidGlyphsView.glyphs.map(\.origin)
    }

    private func layoutOverlaidGlyphs() {
        var glyphs: [(glyph: OverlaidGlyph, origin: CGPoint)] = []
        var decorations: TextLayout?
        if bounds.width > 0, let layoutManager = textLayoutManager, let contentStorage = layoutManager.textContentManager as? NSTextContentStorage {
            let layout = TextLayout(
                width: bounds.width, direction: effectiveUserInterfaceLayoutDirection, contentStorage: contentStorage, layoutManager: layoutManager,
                overlaidText: attributedText
            )
            glyphs = TextKitLabelLayout.overlaidGlyphs(of: layout, below: .greatestFiniteMagnitude)
            if !glyphs.isEmpty, let text = TextKitLabelLayout.overlaidGlyphDecorations(attributedText) {
                let style = TextKitLabelLayout.Style(font: nil, textColor: nil, lineBreakMode: .byWordWrapping, direction: effectiveUserInterfaceLayoutDirection, displayScale: traitCollection.displayScale)
                decorations = TextKitLabelLayout.layout(of: text, width: bounds.width, maximumLines: 0, style: style)
            }
        }
        bringSubviewToFront(overlaidGlyphsView)
        overlaidGlyphsView.frame = bounds
        overlaidGlyphsView.content = (glyphs, decorations)
    }

    private func layoutQuoteBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        quoteBarFrames = []
        if bounds.width > 0, QuoteBars.appear(in: attributedText),
           let layoutManager = textLayoutManager, let contentStorage = layoutManager.textContentManager as? NSTextContentStorage {
            let layout = TextLayout(width: bounds.width, direction: effectiveUserInterfaceLayoutDirection, contentStorage: contentStorage, layoutManager: layoutManager)
            quoteBarFrames = QuoteBars.frames(in: layout, bounds: bounds)
        }
        let path = CGMutablePath()
        path.addRects(quoteBarFrames)
        quoteBarLayer.path = path
        quoteBarLayer.fillColor = QuoteBars.color.resolvedColor(with: traitCollection).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 本文の全体を選び、編集メニューを出す。Macでは出さない。右クリックやキー操作でコピーなどを行えるため。
    func beginSelectingAll() {
        becomeFirstResponder()
        selectedRange = NSRange(location: 0, length: attributedText.length)
        if !ProcessInfo.processInfo.isiOSAppOnMac {
            presentEditMenu()
        }
    }

    /// 選んだ範囲の上に編集メニューを出す。プログラムで選んだだけでは出ず、選んだ文字をタップし直さないと出ないため、
    /// 自分で付けた編集メニューのinteractionで出す。項目は、テキストビューが行える標準の操作（コピー、調べる、翻訳、ウェブを検索、共有など）から組まれる。
    private func presentEditMenu() {
        let rect = selectionFrame
        guard !rect.isNull else { return }
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    /// 選んだ文字の枠。選んでいなければnull。
    private var selectionFrame: CGRect {
        guard let range = selectedTextRange else { return .null }
        return selectionRects(for: range).map(\.rect).filter { $0.width > 0 }.reduce(CGRect.null) { $0.union($1) }
    }

    /// 編集メニューが避ける枠。選んだ文字に重ねず、その上か下に出す。
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        selectionFrame
    }

    /// 同じ本文の描き直し（絵文字の画像が届いた、絵文字が編集されたなど）で、選んだ範囲を保ったまま中身を替える。
    func replaceText(_ text: NSAttributedString) {
        let range = selectedRange
        // 中身を替えると選択が一度空になるので、その間は終わりを受け取らない。
        let onEnd = self.onEnd
        self.onEnd = nil
        attributedText = text
        setNeedsLayout()
        selectedRange = NSRange(location: min(range.location, text.length), length: min(range.length, text.length - min(range.location, text.length)))
        self.onEnd = onEnd
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard let height = touchableHeight?() else { return true }
        return point.y <= height
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // マウスやトラックパッドのクリックとドラッグは、語や範囲に広げる前に一度選択を空にするので、空になってもやめない。
        if selectedRange.length == 0, lastTouchType != .indirectPointer {
            onEnd?()
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onEnd?()
        }
        return resigned
    }

    /// 選んだ範囲の文字は、カスタム絵文字を`:shortcode:`にして返す。編集メニューの調べる、翻訳、ウェブを検索、共有は、選んだ範囲の文字をここから読むため。
    /// 選んだ範囲のほかは、文字を並べた位置と文字数をそろえたまま返す。UIKitが位置の計算に読むことがあり、文字数が変わると位置がずれるため。
    override func text(in range: UITextRange) -> String? {
        let start = offset(from: beginningOfDocument, to: range.start)
        let length = offset(from: range.start, to: range.end)
        guard length > 0, NSRange(location: start, length: length) == selectedRange else { return super.text(in: range) }
        return attributedText.attributedSubstring(from: selectedRange).copiedPlainText
    }

    /// 書式を落とし、カスタム絵文字を`:shortcode:`にしてコピーする。投稿のメニューの「テキストをコピー」と同じ形にするため。
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        UIPasteboard.general.string = attributedText.attributedSubstring(from: selectedRange).copiedPlainText
    }
}

extension NSAttributedString {
    /// RichTextRendererで描いた本文を、アプリの外に貼る文字にする。カスタム絵文字は`:shortcode:`に、段落の中の改行（行区切り文字）は改行にする。
    /// 絵文字の前に置いた幅のない文字（`leadingEmojiGuard`）は除く。場所取りに置き換えた絵文字（`TextKitLabelLayout.placingOverlaidGlyphs(_:)`）は、元の絵文字に戻す。
    var copiedPlainText: String {
        var result = ""
        enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, range, _ in
            if attributes[.leadingEmojiGuard] != nil || attributes[.overlaidGlyphFiller] != nil {
                return
            }
            if let glyph = attributes[.overlaidGlyph] as? OverlaidGlyph {
                // 同じ絵文字が並ぶと1つの範囲にまとまるので、場所取り1つが1文字であることから数を戻す。
                result += String(repeating: glyph.text, count: range.length)
                return
            }
            if let emoji = attributes[.customEmoji] as? CustomEmoji {
                // 同じ絵文字が並ぶと1つの範囲にまとまるので、絵文字1つが1文字であることから数を戻す。
                result += String(repeating: ":\(emoji.shortcode):", count: range.length)
            } else {
                result += (string as NSString).substring(with: range).replacingOccurrences(of: "\u{2028}", with: "\n")
            }
        }
        return result
    }

    /// サーバーが縮めて見せるURLを、元の文字（`RichText.CopiedLinkText`）に戻す。「テキストを選択」で、選んだ文字がそのまま渡るように出すのに使う。
    /// 書式で分かれた1つのリンクは、先頭の部分の書式で全体を描く。戻すURLがなければnil。
    var expandingCopiedLinks: NSAttributedString? {
        var links: [(range: NSRange, link: RichText.CopiedLinkText)] = []
        enumerateAttribute(.copiedLinkText, in: NSRange(location: 0, length: length)) { value, range, _ in
            guard let link = value as? RichText.CopiedLinkText else { return }
            // 属性の範囲は、書式などほかの属性が変わると1つのリンクの中でも分かれるので、続く同じリンクは1つにまとめる。
            if let last = links.last, last.link == link, NSMaxRange(last.range) == range.location {
                links[links.count - 1].range.length += range.length
            } else {
                links.append((range, link))
            }
        }
        guard !links.isEmpty else { return nil }
        let result = NSMutableAttributedString(attributedString: self)
        for (range, link) in links.reversed() {
            var attributes = attributes(at: range.location, effectiveRange: nil)
            attributes[.copiedLinkText] = nil
            result.replaceCharacters(in: range, with: NSAttributedString(string: link.text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attributes))
        }
        return result
    }
}

/// 選べるテキストビューの上に、場所取りに置き換えた字形を描くビュー。押下は受けない。
private final class OverlaidGlyphsView: UIView {
    /// 描く字形と位置、字形の上に引き直す取り消し線と下線の並び（`TextKitLabelLayout.overlaidGlyphDecorations(_:)`）。
    var content: (glyphs: [(glyph: OverlaidGlyph, origin: CGPoint)], decorations: TextLayout?) = ([], nil) {
        didSet { setNeedsDisplay() }
    }

    var glyphs: [(glyph: OverlaidGlyph, origin: CGPoint)] { content.glyphs }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for (glyph, origin) in content.glyphs {
            glyph.draw(atBaseline: origin, in: context)
        }
        guard let decorations = content.decorations else { return }
        decorations.layoutManager.enumerateTextLayoutFragments(from: decorations.layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return true
        }
    }
}
