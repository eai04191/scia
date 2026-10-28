import SciaCore
import UIKit

/// プロフィールの自己紹介の下に出す、自分にしか見えないメモの欄。決まりはdocs/profile.mdの「メモ」にある。
/// 文字の大きさと余白は補足情報のカードに揃え、見分けるために、カードの色を付けず、見出しに錠のアイコンを付ける。押すと、メモのシートを開く。
final class ProfilePrivateNoteView: UIView {
    var onTap: (() -> Void)?
    /// 欄の角の丸み。長押しで持ち上げるときも、この形で持ち上げる。
    static let cornerRadius: CGFloat = 16

    private let iconView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous

        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        iconView.tintColor = .secondaryLabel
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.text = "メモ"
        titleLabel.font = .preferredFont(forTextStyle: .footnote)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        let titleRow = UIStackView(arrangedSubviews: [iconView, titleLabel])
        titleRow.spacing = 4
        titleRow.alignment = .center

        bodyLabel.numberOfLines = 0
        bodyLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [titleRow, bodyLabel])
        stack.axis = .vertical
        // 本文を欄の幅で折り返すため、幅いっぱいに広げる。左に寄せると、本文の幅が決まらず、欄の半分ほどで折り返した。
        stack.alignment = .fill
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "メモを編集します"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// メモを出す。サーバーはメモを整形しないので、書いたままの平文で出す。
    func apply(note: String, glyphLanguage: String, emojiImages: EmojiImageStore) {
        bodyLabel.attributedText = RichTextRenderer(font: .preferredFont(forTextStyle: .subheadline), textColor: .label, emojiImages: emojiImages, language: glyphLanguage)
            .render(.plain(note, emojis: []))
        accessibilityLabel = "メモ、\(note)"
    }

    @objc private func tapped() {
        onTap?()
    }
}
