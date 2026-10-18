import SciaCore
import UIKit

/// Xの投稿へのリンクを、作者、本文、添付ファイルの囲みで出す。fxtwitterから読み終えた投稿にだけ、リンクカードの代わりに置く。
///
/// 表示の試作。囲みの形は、引用の見せ方を決めるときの下書きにする。添付ファイルはMastodonの投稿と同じ部品で並べ、同じビューアで開く。
/// 囲みのどこかが押されたら、リンクと同じくXの投稿を開く。サムネイルの押下は、並べた部品が受ける。
final class XPostView: UIButton {
    struct Content: Equatable {
        var post: XPost
        /// 作者のアイコン。作者の行の先頭に置く。
        var avatar: AvatarView.Content
        var avatarSize: CGFloat
        /// 作者の行の文字。名前は太く、`@`から始まる名前は控えめに描く。
        var name: NSAttributedString
        var text: NSAttributedString
        /// 添付ファイルがなければnil。
        var media: MediaGridView.Content?
        /// 囲みの内側の余白。
        var padding: CGFloat
        /// 作者の行と本文、本文と添付ファイルのあいだ。
        var spacing: CGFloat
        /// リンクカードから替わったときに、囲みを浮かび上がらせる時間。
        var transitionDuration: TimeInterval
    }

    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    /// 閲覧注意の覆いが押されたときに呼ぶ。
    var onRevealMedia: (() -> Void)?

    private let avatarView: AvatarView
    private let nameLabel = UILabel()
    private let textLabel = UILabel()
    private let mediaView: MediaGridView
    /// アイコンと名前を並べる作者の行。
    private let headerGuide = UILayoutGuide()
    private(set) var content: Content?
    private var variableConstraints: [NSLayoutConstraint] = []

    /// 表示中のサムネイル。ビューアの拡大と縮小の起点を探すときに使う。
    var mediaGrid: MediaGridView? {
        mediaView.isHidden ? nil : mediaView
    }

    init(store: MediaImageStore, avatarImages: AvatarImageStore) {
        mediaView = MediaGridView(store: store)
        avatarView = AvatarView(store: avatarImages)
        super.init(frame: .zero)
        layer.cornerRadius = MediaGridView.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        // 試作のため、読み上げでは作者の行、本文、サムネイルを別々の要素として読む。囲みを押してXの投稿を開く操作は、読み上げからはできない。
        isAccessibilityElement = false
        nameLabel.lineBreakMode = .byTruncatingTail
        textLabel.numberOfLines = 0
        for view in [avatarView, nameLabel, textLabel] as [UIView] {
            view.isUserInteractionEnabled = false
        }
        for view in [avatarView, nameLabel, textLabel, mediaView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addLayoutGuide(headerGuide)
        mediaView.onSelect = { [weak self] index in
            guard let self else { return }
            self.onSelectMedia?(index, self.mediaView)
        }
        mediaView.onReveal = { [weak self] in self?.onRevealMedia?() }
        updateBorderColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, UITraitDisplayScale.self]) { (self: Self, _) in
            self.updateBorderColor()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        avatarView.apply(content.avatar)
        nameLabel.attributedText = content.name
        textLabel.attributedText = content.text
        textLabel.isHidden = content.text.length == 0
        NSLayoutConstraint.deactivate(variableConstraints)
        let padding = content.padding
        // 作者の行の高さは、アイコンと名前の高いほう。どちらも行の上下中央に揃える。
        var constraints = [
            headerGuide.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            headerGuide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            headerGuide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            headerGuide.heightAnchor.constraint(greaterThanOrEqualToConstant: content.avatarSize),
            nameLabel.topAnchor.constraint(greaterThanOrEqualTo: headerGuide.topAnchor),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: headerGuide.bottomAnchor),
            avatarView.leadingAnchor.constraint(equalTo: headerGuide.leadingAnchor),
            avatarView.centerYAnchor.constraint(equalTo: headerGuide.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: content.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: content.avatarSize),
            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: content.spacing),
            nameLabel.trailingAnchor.constraint(equalTo: headerGuide.trailingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: headerGuide.centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            textLabel.topAnchor.constraint(equalTo: headerGuide.bottomAnchor, constant: content.spacing),
        ]
        // 下限だけでは高さが決まらないため、収まる最小の高さに寄せる。
        let compactHeader = headerGuide.heightAnchor.constraint(equalToConstant: 0)
        compactHeader.priority = .defaultLow
        constraints.append(compactHeader)
        var last = textLabel.isHidden ? headerGuide.bottomAnchor : textLabel.bottomAnchor
        if let media = content.media, let aspectRatio = media.aspectRatio {
            mediaView.isHidden = false
            mediaView.apply(media)
            constraints += [
                mediaView.topAnchor.constraint(equalTo: last, constant: content.spacing),
                mediaView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                mediaView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
                mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: 1 / aspectRatio),
            ]
            last = mediaView.bottomAnchor
        } else {
            mediaView.isHidden = true
        }
        constraints.append(bottomAnchor.constraint(equalTo: last, constant: padding))
        variableConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .systemFill : nil }
    }

    private func updateBorderColor() {
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    }
}
