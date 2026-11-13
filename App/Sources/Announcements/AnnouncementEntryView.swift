import SciaCore
import UIKit

/// お知らせの1件。日時と未読の点、本文、リアクションを縦に並べる。決まりはdocs/announcements.mdの「行」にある。
final class AnnouncementEntryView: UIView {
    struct Content {
        var date: String
        var showsUnreadMark: Bool
        var body: NSAttributedString
        /// サーバーがリアクションを許していなければnil。
        var reactions: [ReactionChipsView.Reaction]?
        /// 動くカスタム絵文字を動かすときのストア。nilなら動かさない。
        var animatedEmojis: EmojiImageStore<UIImage>?
    }

    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// リアクションを押したときに、その絵文字の名前を渡して呼ぶ。
    var onToggleReaction: ((String) -> Void)?
    /// 「＋」を押したときに呼ぶ。
    var onAddReaction: (() -> Void)?

    private let dateLabel = UILabel()
    private let unreadMark = UIView()
    private let bodyLabel = LinkLabel()
    private let reactionsView = ReactionChipsView()
    private static let unreadMarkSize: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        dateLabel.font = .preferredFont(forTextStyle: .subheadline)
        dateLabel.textColor = .secondaryLabel
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.numberOfLines = 0
        // 上に何も載せない点なので、ティントカラーをそのまま塗る。
        // scialint:disable:next raw_tint_background
        unreadMark.backgroundColor = .tintColor
        unreadMark.layer.cornerRadius = Self.unreadMarkSize / 2
        unreadMark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            unreadMark.widthAnchor.constraint(equalToConstant: Self.unreadMarkSize),
            unreadMark.heightAnchor.constraint(equalToConstant: Self.unreadMarkSize),
        ])
        let header = UIStackView(arrangedSubviews: [dateLabel, unreadMark, UIView()])
        header.spacing = 6
        header.alignment = .center
        bodyLabel.numberOfLines = 0
        bodyLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
        reactionsView.onToggle = { [weak self] name in self?.onToggleReaction?(name) }
        reactionsView.onAdd = { [weak self] in self?.onAddReaction?() }
        let stack = UIStackView(arrangedSubviews: [header, bodyLabel, reactionsView])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: Content) {
        dateLabel.text = content.date
        dateLabel.accessibilityLabel = content.showsUnreadMark ? "\(content.date)、未読" : content.date
        unreadMark.isHidden = !content.showsUnreadMark
        bodyLabel.emojiImages = content.animatedEmojis
        bodyLabel.attributedText = content.body
        bodyLabel.accessibilityCustomActions = LinkLabel.links(in: content.body).map { text, destination in
            UIAccessibilityCustomAction(name: text) { [weak self] _ in
                self?.onOpenLink?(destination)
                return true
            }
        }
        reactionsView.isHidden = content.reactions == nil
        reactionsView.animatedEmojis = content.animatedEmojis
        reactionsView.apply(content.reactions ?? [])
    }
}
