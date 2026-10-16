import SciaCore
import UIKit

/// RichTextRendererで描いた本文の、リンクの部分をタップできるラベル。リンクの外のタップは受けず、セルなど後ろのビューに渡す。
final class LinkLabel: UILabel {
    /// リンクがタップされたときに、その行き先を渡して呼ぶ。
    var onTapLink: ((RichText.LinkDestination) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let destination = link(at: recognizer.location(in: self)) else { return }
        onTapLink?(destination)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view === self else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        return link(at: gestureRecognizer.location(in: self)) != nil
    }

    /// ラベルの座標`point`にある文字のリンクの行き先。リンクでなければnil。
    /// UILabelは文字の配置を公開しないため、同じ文字列と幅でTextKit 2に並べ直して文字を探す。
    /// TextKit 1（NSLayoutManager）で並べると、空行や行区切り文字のたびに行の位置がUILabelの描画から数ptずつずれ、
    /// 空行の多い本文では末尾のリンクを外していた。TextKit 2の行の位置は、UILabelが描いた位置と一致することを確かめている。
    /// ラベルは本文の高さに合わせて置くため、UILabelが余った高さで文字を縦に中央へ寄せる分はずれとして扱わない。
    func link(at point: CGPoint) -> RichText.LinkDestination? {
        guard let attributedText, attributedText.length > 0, bounds.contains(point) else { return nil }
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
        guard let index = candidates.first(where: { characterFrame(at: $0, in: contentStorage, layoutManager: layoutManager)?.contains(point) ?? false }) else { return nil }
        return attributedText.attribute(.linkDestination, at: index, effectiveRange: nil) as? RichText.LinkDestination
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
    private func characterFrame(at index: Int, in contentStorage: NSTextContentStorage, layoutManager: NSTextLayoutManager) -> CGRect? {
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
