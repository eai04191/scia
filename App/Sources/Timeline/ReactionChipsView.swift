import SciaCore
import UIKit

/// リアクションを、絵文字と数のボタンで並べ、入りきらなければ折り返す。最後に、絵文字のシートを開く「＋」を置く。サーバーのお知らせと投稿で使う。
final class ReactionChipsView: UIView {
    struct Reaction {
        var name: String
        /// 絵文字を描いた文字。カスタム絵文字は画像で描く。
        var emoji: NSAttributedString
        var count: Int
        var isMine: Bool
        /// 読み上げで絵文字の代わりに読む文字。カスタム絵文字はショートコード。
        var spokenName: String
    }

    /// ボタンの文字と大きさ。投稿では「投稿の見た目」の値で決め、サーバーのお知らせでは`standard`を使う。
    struct Style: Equatable {
        /// 絵文字と数の文字。数は、この文字で数字の幅を揃えて描く。
        var font: UIFont
        /// ボタンどうしのあいだ。折り返した行のあいだも同じにする。
        var spacing: CGFloat
        /// ボタンの文字の上下と左右の余白。
        var padding: NSDirectionalEdgeInsets

        static var standard: Style {
            Style(font: .preferredFont(forTextStyle: .subheadline), spacing: 6, padding: NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
        }
    }

    /// リアクションを押したときに、その絵文字の名前を渡して呼ぶ。
    var onToggle: ((String) -> Void)?
    /// 「＋」を押したときに呼ぶ。
    var onAdd: (() -> Void)?
    /// 動くカスタム絵文字を動かすときのストア。nilなら動かさない。
    var animatedEmojis: EmojiImageStore<UIImage>?
    /// まだ幅が決まっていないときに、高さを測る幅。一覧の行は、幅が決まる前に高さを測ることがあり、0の幅で測るとボタンが1つずつ折り返して高く測られるため。
    var widthHint: CGFloat?
    /// 幅が決まって、測った高さが変わったときに呼ぶ。置いている一覧の行に高さを測り直させる。
    var onHeightChange: (() -> Void)?
    /// 「＋」を出すか。
    var showsAddButton = true {
        didSet {
            guard showsAddButton != oldValue else { return }
            arrangeButtons()
        }
    }
    private var reactionOrder: [String] = []
    private(set) var style = Style.standard

    /// 並べている順のボタン。最後は「＋」。
    private var buttons: [UIControl] = []
    /// 絵文字の名前ごとのボタン。描き直しでも同じリアクションのボタンは使い回し、押している途中のボタンを作り替えてタップを取り消さない。
    private var reactionButtons: [String: ReactionChipButton] = [:]
    private lazy var addButton = makeAddButton()
    /// 最後に知らせた高さ。置かれた幅で並べた高さと違えば、測り直させる。
    private var reportedHeight: CGFloat?

    func apply(_ reactions: [Reaction], style: Style = .standard) {
        if style != self.style {
            self.style = style
            applyStyle(to: addButton)
            addButton.label.attributedText = addSymbol()
        }
        var used: [String: ReactionChipButton] = [:]
        for reaction in reactions {
            let button = reactionButtons[reaction.name] ?? makeButton(name: reaction.name)
            configure(button, with: reaction)
            used[reaction.name] = button
        }
        for (name, button) in reactionButtons where used[name] == nil {
            button.removeFromSuperview()
        }
        reactionButtons = used
        reactionOrder = reactions.map(\.name)
        arrangeButtons()
    }

    private func arrangeButtons() {
        buttons = reactionOrder.compactMap { reactionButtons[$0] } + (showsAddButton ? [addButton] : [])
        if !showsAddButton {
            addButton.removeFromSuperview()
        }
        for button in buttons where button.superview !== self {
            addSubview(button)
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let height = layout(width: measuringWidth).height
        reportedHeight = height
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    private var measuringWidth: CGFloat {
        bounds.width > 0 ? bounds.width : widthHint ?? bounds.width
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = layout(width: bounds.width).frames
        for (button, frame) in zip(buttons, frames) {
            button.frame = frame
        }
        // 測ったときの幅と違う幅に置かれて高さが変わったら、測り直させる。
        if bounds.width > 0, layout(width: bounds.width).height != reportedHeight {
            invalidateIntrinsicContentSize()
            onHeightChange?()
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
                y += rowHeight + style.spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: fitted))
            x += fitted.width + style.spacing
            rowHeight = max(rowHeight, fitted.height)
        }
        return (frames, y + rowHeight)
    }

    /// 「投稿の見た目」のプレビューで、ボタンの場所を示すための枠。`space`の座標で、並べた順に返す。
    func chipPreviewFrames(in space: UIView) -> [CGRect] {
        buttons.map { convert($0.frame, to: space) }
    }

    private func applyStyle(to button: ReactionChipButton) {
        button.label.font = style.font
        button.padding = style.padding
        button.setNeedsLayout()
    }

    private func makeButton(name: String) -> ReactionChipButton {
        let button = ReactionChipButton()
        applyStyle(to: button)
        button.addAction(UIAction { [weak self] _ in self?.onToggle?(name) }, for: .touchUpInside)
        return button
    }

    private func configure(_ button: ReactionChipButton, with reaction: Reaction) {
        let text = NSMutableAttributedString(attributedString: reaction.emoji)
        text.append(NSAttributedString(string: " \(reaction.count.formatted())", attributes: [
            .font: style.font.withMonospacedDigits,
            .foregroundColor: reaction.isMine ? UIColor.tintColor : UIColor.label,
        ]))
        applyStyle(to: button)
        button.label.emojiImages = animatedEmojis
        button.label.attributedText = text
        button.isMine = reaction.isMine
        button.accessibilityLabel = "\(reaction.spokenName) \(reaction.count.formatted())件"
        button.accessibilityValue = reaction.isMine ? "リアクション済み" : nil
        button.accessibilityTraits = reaction.isMine ? [.button, .selected] : .button
        button.setNeedsLayout()
    }

    private func makeAddButton() -> ReactionChipButton {
        let button = ReactionChipButton()
        applyStyle(to: button)
        button.label.attributedText = addSymbol()
        button.label.textColor = .secondaryLabel
        button.accessibilityLabel = "リアクションを追加"
        button.accessibilityTraits = .button
        button.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        return button
    }

    /// 「＋」の記号。絵文字と数の文字の大きさで描く。
    private func addSymbol() -> NSAttributedString {
        let configuration = UIImage.SymbolConfiguration(font: style.font)
        return NSAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "plus", withConfiguration: configuration) ?? UIImage()))
    }
}

/// リアクションのボタン。カスタム絵文字を本文と同じく動かすため、`UIButton`ではなく`EmojiLabel`を載せる。自分がしたものはアプリの色で塗る。
final class ReactionChipButton: UIControl {
    let label = EmojiLabel()
    var padding = ReactionChipsView.Style.standard.padding {
        didSet { setNeedsLayout() }
    }
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
        let side = sidePadding(within: size.width)
        let labelSize = label.sizeThatFits(CGSize(width: size.width - side.leading - side.trailing, height: .greatestFiniteMagnitude))
        let lineHeight = ceil(label.font.lineHeight)
        return CGSize(width: max(ceil(labelSize.width) + side.leading + side.trailing, 44), height: lineHeight + padding.top + padding.bottom)
    }

    /// 幅`width`に置くときの左右の余白。余白で幅の半分より多くを取らないよう、左右の比を保って縮める。
    /// 「投稿の見た目」で余白を大きくし、列が狭いとき（アイコンを大きくして下を空けるときなど）に、文字の幅が負にならないようにするため。
    func sidePadding(within width: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let total = padding.leading + padding.trailing
        let limit = max(width, 0) / 2
        guard total > limit, total > 0 else { return (padding.leading, padding.trailing) }
        let scale = limit / total
        return (padding.leading * scale, padding.trailing * scale)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        // 中身の高さのまま縦の真ん中に置く。行より高い中身も、切らずにはみ出させる。
        let side = sidePadding(within: bounds.width)
        let width = bounds.width - side.leading - side.trailing
        let height = ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        label.frame = CGRect(x: side.leading, y: (bounds.height - height) / 2, width: width, height: height)
        label.textAlignment = .center
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let extra = max(0, Self.minimumHitHeight - bounds.height) / 2
        return bounds.insetBy(dx: 0, dy: -extra).contains(point)
    }

    // 枠の色はCGColorで、ティントカラーが変わっても描き直されないため、変わったら当て直す。
    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    private func updateColors() {
        backgroundColor = isMine ? tintColor.withAlphaComponent(0.18) : .secondarySystemFill
        layer.borderWidth = isMine ? 1 : 0
        layer.borderColor = tintColor.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
    }
}
