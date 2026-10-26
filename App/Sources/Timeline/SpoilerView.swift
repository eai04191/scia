import UIKit

/// 注意書き（CW）。本文の上に置き、押すと本文を開閉する。フィルターの警告も、同じボックスで本文の代わりに出す。
///
/// 注意書きはただの文字と見分けがつくよう、地の色を敷いたボックスに入れ、押せることが分かるよう、開閉の文言と記号を添える。
final class SpoilerView: UIControl {
    struct Content: Equatable {
        var text: NSAttributedString
        var isCollapsed: Bool
        var kind: PostBodyContent.Spoiler.Kind
        /// ボックスの内側の余白。
        var padding: CGFloat
        /// 開閉のボタンの文字。
        var buttonFont: UIFont
        /// 注意書きの文字と、開閉のボタンのあいだ。
        var buttonSpacing: CGFloat
        /// ボックスの角の丸み。
        var cornerRadius: CGFloat
    }

    private let textLabel = EmojiLabel()
    private let toggleLabel = UILabel()
    private var paddingConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerCurve = .continuous
        textLabel.numberOfLines = 0
        toggleLabel.textColor = .tintColor
        for label in [textLabel, toggleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            toggleLabel.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
            toggleLabel.trailingAnchor.constraint(lessThanOrEqualTo: textLabel.trailingAnchor),
        ])
        // 読み上げでは、投稿の本文と1つの要素で読み、開閉はその要素の操作から行う。
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 注意書きのアニメーションするカスタム絵文字を動かすときに、アニメーション版を読み込むストア。nilなら動かさない。
    var emojiImages: EmojiImageStore? {
        get { textLabel.emojiImages }
        set { textLabel.emojiImages = newValue }
    }

    func apply(_ content: Content) {
        textLabel.attributedText = content.text
        layer.cornerRadius = content.cornerRadius
        toggleLabel.font = content.buttonFont
        toggleLabel.attributedText = Self.toggleText(isCollapsed: content.isCollapsed, kind: content.kind, font: toggleLabel.font)
        NSLayoutConstraint.deactivate(paddingConstraints)
        paddingConstraints = [
            textLabel.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: content.padding + PostBodyView.textTopInset(of: content.text)),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: content.padding),
            toggleLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: content.buttonSpacing),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -content.padding),
            bottomAnchor.constraint(equalTo: toggleLabel.lastBaselineAnchor, constant: content.padding + toggleLabel.font.pointSize * PostBodyView.emBoxDescent),
        ]
        NSLayoutConstraint.activate(paddingConstraints)
    }

    /// 開閉のボタンの文字の枠。「投稿の見た目」のプレビューで場所を示すときに使う。
    func buttonPreviewFrame(in space: UIView) -> [CGRect]? {
        toggleLabel.previewFrame(in: space)
    }

    /// 注意書きの文字の枠。「投稿の見た目」のプレビューで、文字と開くボタンのあいだを示すときに使う。
    func textPreviewFrame(in space: UIView) -> [CGRect]? {
        textLabel.previewFrame(in: space)
    }

    static func toggleTitle(isCollapsed: Bool, kind: PostBodyContent.Spoiler.Kind) -> String {
        switch kind {
        case .contentWarning: isCollapsed ? "本文を表示" : "本文を隠す"
        // フィルターの警告は、本文だけでなく添付ファイルやリンクカードも隠しているため、本文に限らない言い方にする。
        case .filter: "投稿を表示"
        }
    }

    static func toggleText(isCollapsed: Bool, kind: PostBodyContent.Spoiler.Kind, font: UIFont) -> NSAttributedString {
        let text = NSMutableAttributedString(string: toggleTitle(isCollapsed: isCollapsed, kind: kind) + " ")
        let symbol = UIImage(
            systemName: isCollapsed ? "chevron.down" : "chevron.up",
            withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)
        )
        if let symbol {
            text.append(NSAttributedString(attachment: NSTextAttachment(image: symbol.withRenderingMode(.alwaysTemplate))))
        }
        // 記号は文字と同じ色で描くよう、文字色を属性で付けておく。
        text.addAttribute(.foregroundColor, value: UIColor.tintColor, range: NSRange(location: 0, length: text.length))
        return text
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }
}
