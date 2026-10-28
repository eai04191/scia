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
    var copiedPlainText: String {
        var result = ""
        enumerateAttribute(.customEmoji, in: NSRange(location: 0, length: length)) { value, range, _ in
            if let emoji = value as? CustomEmoji {
                // 同じ絵文字が並ぶと1つの範囲にまとまるので、絵文字1つが1文字であることから数を戻す。
                result += String(repeating: ":\(emoji.shortcode):", count: range.length)
            } else {
                result += (string as NSString).substring(with: range).replacingOccurrences(of: "\u{2028}", with: "\n")
            }
        }
        return result
    }
}
