import SciaCore
import UIKit

/// お知らせのリアクションを、絵文字と数のボタンで並べ、入りきらなければ折り返す。最後に、絵文字のシートを開く「＋」を置く。
final class AnnouncementReactionsView: UIView {
    struct Reaction {
        var name: String
        /// 絵文字を描いた文字。カスタム絵文字は画像で描く。
        var emoji: NSAttributedString
        var count: Int
        var isMine: Bool
        /// 読み上げで絵文字の代わりに読む文字。カスタム絵文字はショートコード。
        var spokenName: String
    }

    /// リアクションを押したときに、その絵文字の名前を渡して呼ぶ。
    var onToggle: ((String) -> Void)?
    /// 「＋」を押したときに呼ぶ。
    var onAdd: (() -> Void)?
    /// 動くカスタム絵文字を動かすときのストア。nilなら動かさない。
    var animatedEmojis: EmojiImageStore<UIImage>?

    /// 並べている順のボタン。最後は「＋」。
    private var buttons: [UIControl] = []
    /// 絵文字の名前ごとのボタン。描き直しでも同じリアクションのボタンは使い回し、押している途中のボタンを作り替えてタップを取り消さない。
    private var reactionButtons: [String: AnnouncementReactionButton] = [:]
    private lazy var addButton = makeAddButton()
    private static let spacing: CGFloat = 6
    /// 最後に並べた幅。幅が変わったら高さを測り直す。
    private var measuredWidth: CGFloat = 0

    func apply(_ reactions: [Reaction]) {
        var used: [String: AnnouncementReactionButton] = [:]
        for reaction in reactions {
            let button = reactionButtons[reaction.name] ?? makeButton(name: reaction.name)
            configure(button, with: reaction)
            used[reaction.name] = button
        }
        for (name, button) in reactionButtons where used[name] == nil {
            button.removeFromSuperview()
        }
        reactionButtons = used
        buttons = reactions.compactMap { used[$0.name] } + [addButton]
        for button in buttons where button.superview !== self {
            addSubview(button)
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: layout(width: bounds.width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = layout(width: bounds.width).frames
        for (button, frame) in zip(buttons, frames) {
            button.frame = frame
        }
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    /// 左から詰めて並べ、幅を超えたら次の行へ送る。
    private func layout(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for button in buttons {
            let size = button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let fitted = CGSize(width: min(size.width, max(width, 1)), height: size.height)
            if x > 0, x + fitted.width > width {
                x = 0
                y += rowHeight + Self.spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: fitted))
            x += fitted.width + Self.spacing
            rowHeight = max(rowHeight, fitted.height)
        }
        return (frames, y + rowHeight)
    }

    private func makeButton(name: String) -> AnnouncementReactionButton {
        let button = AnnouncementReactionButton()
        button.addAction(UIAction { [weak self] _ in self?.onToggle?(name) }, for: .touchUpInside)
        return button
    }

    private func configure(_ button: AnnouncementReactionButton, with reaction: Reaction) {
        let text = NSMutableAttributedString(attributedString: reaction.emoji)
        text.append(NSAttributedString(string: " \(reaction.count)", attributes: [
            .font: UIFont.monospacedDigitFont(forTextStyle: .subheadline),
            .foregroundColor: reaction.isMine ? UIColor.tintColor : UIColor.label,
        ]))
        button.label.emojiImages = animatedEmojis
        button.label.attributedText = text
        button.isMine = reaction.isMine
        button.accessibilityLabel = "\(reaction.spokenName) \(reaction.count)件"
        button.accessibilityValue = reaction.isMine ? "リアクション済み" : nil
        button.accessibilityTraits = reaction.isMine ? [.button, .selected] : .button
        button.setNeedsLayout()
    }

    private func makeAddButton() -> UIControl {
        let button = AnnouncementReactionButton()
        let symbol = NSTextAttachment(image: UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline)) ?? UIImage())
        button.label.attributedText = NSAttributedString(attachment: symbol)
        button.label.textColor = .secondaryLabel
        button.accessibilityLabel = "リアクションを追加"
        button.accessibilityTraits = .button
        button.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        return button
    }
}

/// リアクションのボタン。カスタム絵文字を本文と同じく動かすため、`UIButton`ではなく`EmojiLabel`を載せる。自分がしたものはアプリの色で塗る。
private final class AnnouncementReactionButton: UIControl {
    let label = EmojiLabel()
    private static let padding = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
    /// 押せる範囲の高さ。見た目は小さくても、押せる範囲は44pt取る。
    private static let minimumHitHeight: CGFloat = 44

    var isMine = false {
        didSet { updateColors() }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        layer.cornerCurve = .continuous
        label.numberOfLines = 1
        label.isUserInteractionEnabled = false
        label.font = .preferredFont(forTextStyle: .subheadline)
        addSubview(label)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.updateColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 高さは中身ではなく文字の行の高さで決める。カスタム絵文字の画像はUnicodeの絵文字より行を少し高くするため、中身で決めると並んだボタンの高さが揃わない。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let padding = Self.padding
        let labelSize = label.sizeThatFits(CGSize(width: size.width - padding.leading - padding.trailing, height: .greatestFiniteMagnitude))
        let lineHeight = ceil(label.font.lineHeight)
        return CGSize(width: max(ceil(labelSize.width) + padding.leading + padding.trailing, 44), height: lineHeight + padding.top + padding.bottom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        let padding = Self.padding
        // 中身の高さのまま縦の真ん中に置く。行より高い中身も、切らずにはみ出させる。
        let width = bounds.width - padding.leading - padding.trailing
        let height = ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        label.frame = CGRect(x: padding.leading, y: (bounds.height - height) / 2, width: width, height: height)
        label.textAlignment = .center
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let extra = max(0, Self.minimumHitHeight - bounds.height) / 2
        return bounds.insetBy(dx: 0, dy: -extra).contains(point)
    }

    private func updateColors() {
        backgroundColor = isMine ? UIColor.tintColor.withAlphaComponent(0.18) : .secondarySystemFill
        layer.borderWidth = isMine ? 1 : 0
        layer.borderColor = UIColor.tintColor.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
    }
}
