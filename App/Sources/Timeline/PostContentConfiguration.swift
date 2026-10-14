import SciaCore
import UIKit

/// 投稿のセルの中身。左にアイコン、右に名前の行、本文、添付ファイルのサムネイルを並べる。ブーストなら、上にブーストした人の行を足す。
///
/// 名前の行の右端に時刻を置くため、`UIListContentConfiguration`の文字の枠を使わずに組む。
struct PostContentConfiguration: UIContentConfiguration {
    struct Boost {
        let avatar: AvatarView.Content
        let name: NSAttributedString
    }

    var boost: Boost?
    var avatar: AvatarView.Content
    /// 名前の行に並べる文字。先頭を目立たせ、2つ目は控えめに描く。
    var nameParts: [NSAttributedString]
    var createdAt: Date
    var timeStyle: StatusTimeStyle
    var body: NSAttributedString
    var metrics: Metrics
    /// 添付ファイルがなければnil。
    var media: MediaGridView.Content?
    let mediaImages: MediaImageStore
    let avatarImages: AvatarImageStore
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    var onRevealMedia: (() -> Void)?

    /// 大きさと文字の見た目。
    struct Metrics {
        var margins: NSDirectionalEdgeInsets
        var avatarSize: CGFloat
        var boosterAvatarSize: CGFloat
        var nameFont: UIFont
        var secondaryFont: UIFont
    }

    func makeContentView() -> any UIView & UIContentView {
        PostContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> PostContentConfiguration {
        self
    }

    /// `now`の時点での時刻の表記。
    func timeText(now: Date) -> String {
        StatusTimestamp.text(for: createdAt, now: now, style: timeStyle)
    }
}

final class PostContentView: UIView, UIContentView {
    /// アイコンと本文のあいだの余白。
    private static let avatarSpacing: CGFloat = 10
    /// 本文とサムネイルのあいだの余白。
    private static let mediaSpacing: CGFloat = 8
    /// ブーストした人の行と名前の行のあいだの余白。
    private static let boostSpacing: CGFloat = 4

    private let avatarView: AvatarView
    private let boostIcon = UIImageView(image: UIImage(systemName: "arrow.2.squarepath"))
    private let boosterAvatarView: AvatarView
    private let boostLabel = UILabel()
    private let nameLabels = [UILabel(), UILabel()]
    private let timeLabel = UILabel()
    private let nameRow = UIStackView()
    private let bodyLabel = UILabel()
    private let mediaView: MediaGridView
    private let textGuide = UILayoutGuide()
    private var current: PostContentConfiguration

    /// 大きさや有無で変わる制約。適用のたびに作り直す。
    private var variableConstraints: [NSLayoutConstraint] = []

    var configuration: any UIContentConfiguration {
        get { current }
        set {
            guard let configuration = newValue as? PostContentConfiguration else { return }
            apply(configuration)
        }
    }

    /// 表示中のサムネイル。ビューアの拡大と縮小の起点を探すときに使う。
    var mediaGrid: MediaGridView? {
        mediaView.isHidden ? nil : mediaView
    }

    init(configuration: PostContentConfiguration) {
        current = configuration
        avatarView = AvatarView(store: configuration.avatarImages)
        boosterAvatarView = AvatarView(store: configuration.avatarImages)
        mediaView = MediaGridView(store: configuration.mediaImages)
        super.init(frame: .zero)
        addLayoutGuide(textGuide)
        configureSubviews()
        mediaView.onSelect = { [weak self] index in
            guard let self else { return }
            self.current.onSelectMedia?(index, self.mediaView)
        }
        mediaView.onReveal = { [weak self] in self?.current.onRevealMedia?() }
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSubviews() {
        boostIcon.tintColor = .secondaryLabel
        boostIcon.contentMode = .scaleAspectFit
        boostIcon.setContentHuggingPriority(.required, for: .horizontal)
        boostLabel.lineBreakMode = .byTruncatingTail

        // 幅が足りなければ、2つ目（既定ではacct）から先に縮め、時刻は縮めない。
        for (index, label) in nameLabels.enumerated() {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(index == 0 ? .defaultHigh : .defaultLow, for: .horizontal)
            label.setContentHuggingPriority(index == 0 ? .required : .defaultLow, for: .horizontal)
            nameRow.addArrangedSubview(label)
        }
        timeLabel.textColor = .secondaryLabel
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameRow.addArrangedSubview(timeLabel)
        nameRow.axis = .horizontal
        nameRow.alignment = .firstBaseline
        nameRow.spacing = 4
        // 時刻を右端に寄せるため、2つ目の名前が余りの幅を受け持つ。
        nameRow.setCustomSpacing(8, after: nameLabels[1])
        // ベースラインで揃えたスタックは、上下の端が中の文字より外にあればよいという制約になり、高さが決まらない。
        // セルは大きな高さを目安に測るため、何もしないと行がその高さまで伸びる。文字が収まる最小の高さに寄せる。
        let compactNameRow = nameRow.heightAnchor.constraint(equalToConstant: 0)
        compactNameRow.priority = .defaultLow
        compactNameRow.isActive = true

        bodyLabel.numberOfLines = 0

        for view in [avatarView, boostIcon, boosterAvatarView, boostLabel, nameRow, bodyLabel, mediaView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func apply(_ configuration: PostContentConfiguration) {
        current = configuration
        let metrics = configuration.metrics

        avatarView.apply(configuration.avatar)
        let boost = configuration.boost
        boostIcon.isHidden = boost == nil
        boosterAvatarView.isHidden = boost == nil
        boostLabel.isHidden = boost == nil
        boosterAvatarView.apply(boost?.avatar)
        boostLabel.attributedText = boost?.name
        boostIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: metrics.secondaryFont, scale: .small)

        for (index, label) in nameLabels.enumerated() {
            let text = configuration.nameParts.indices.contains(index) ? configuration.nameParts[index] : nil
            label.attributedText = text
            label.isHidden = text == nil
        }
        // 2つ目がないときは、1つ目が余りの幅を受け持つ。
        nameLabels[0].setContentHuggingPriority(configuration.nameParts.count > 1 ? .required : .defaultLow, for: .horizontal)
        timeLabel.font = metrics.secondaryFont
        timeLabel.text = configuration.timeText(now: .now)

        bodyLabel.attributedText = configuration.body

        if let media = configuration.media, media.aspectRatio != nil {
            mediaView.isHidden = false
            mediaView.apply(media)
        } else {
            mediaView.isHidden = true
        }
        updateConstraints(for: configuration)
        updateAccessibility(for: configuration)
    }

    /// 時刻の表記だけを今の時刻で書き直す。名前の行は1行で高さが決まっているため、行の高さは変わらない。
    func refreshTime(now: Date) {
        let text = current.timeText(now: now)
        if timeLabel.text != text {
            timeLabel.text = text
            updateAccessibility(for: current)
        }
    }

    private func updateConstraints(for configuration: PostContentConfiguration) {
        NSLayoutConstraint.deactivate(variableConstraints)
        let metrics = configuration.metrics
        let margins = metrics.margins
        var constraints = [
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margins.leading),
            avatarView.topAnchor.constraint(equalTo: nameRow.topAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: metrics.avatarSize),
            textGuide.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: Self.avatarSpacing),
            textGuide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.trailing),
            nameRow.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
            nameRow.trailingAnchor.constraint(equalTo: textGuide.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: nameRow.bottomAnchor, constant: 2),
            bodyLabel.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: textGuide.trailingAnchor),
            // 本文が短くても、アイコンが下の余白に食い込まないようにする。
            bottomAnchor.constraint(greaterThanOrEqualTo: avatarView.bottomAnchor, constant: margins.bottom),
        ]
        if configuration.boost != nil {
            constraints += [
                boostLabel.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
                boosterAvatarView.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
                boosterAvatarView.centerYAnchor.constraint(equalTo: boostLabel.centerYAnchor),
                boosterAvatarView.widthAnchor.constraint(equalToConstant: metrics.boosterAvatarSize),
                boosterAvatarView.heightAnchor.constraint(equalToConstant: metrics.boosterAvatarSize),
                boostLabel.leadingAnchor.constraint(equalTo: boosterAvatarView.trailingAnchor, constant: 4),
                boostLabel.trailingAnchor.constraint(lessThanOrEqualTo: textGuide.trailingAnchor),
                // 🔁はアイコンの列の右端に揃え、ブーストした人のアイコンと名前は本文の列に揃える。
                boostIcon.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor),
                boostIcon.centerYAnchor.constraint(equalTo: boostLabel.centerYAnchor),
                nameRow.topAnchor.constraint(equalTo: boostLabel.bottomAnchor, constant: Self.boostSpacing),
            ]
        } else {
            constraints.append(nameRow.topAnchor.constraint(equalTo: topAnchor, constant: margins.top))
        }
        let contentBottom: NSLayoutYAxisAnchor
        if mediaView.isHidden {
            contentBottom = bodyLabel.bottomAnchor
        } else if let media = configuration.media, let aspectRatio = media.aspectRatio {
            constraints += [
                mediaView.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: Self.mediaSpacing),
                mediaView.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
                mediaView.trailingAnchor.constraint(equalTo: textGuide.trailingAnchor),
                mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: 1 / aspectRatio),
            ]
            contentBottom = mediaView.bottomAnchor
        } else {
            contentBottom = bodyLabel.bottomAnchor
        }
        // アイコンの方が下まで届くときは、等しさを諦めてアイコンの下に余白を取る。
        let fitsContent = bottomAnchor.constraint(equalTo: contentBottom, constant: margins.bottom)
        fitsContent.priority = .required - 1
        constraints += [
            bottomAnchor.constraint(greaterThanOrEqualTo: contentBottom, constant: margins.bottom),
            fitsContent,
        ]
        variableConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    /// 読み上げでは、ブーストした人、名前、時刻、本文の順に1つの要素として読む。サムネイルは別の要素のまま残す。
    private func updateAccessibility(for configuration: PostContentConfiguration) {
        var parts: [String] = []
        if let boost = configuration.boost {
            parts.append("\(boost.name.string)がブースト")
        }
        parts += configuration.nameParts.map(\.string)
        parts.append(timeLabel.text ?? "")
        parts.append(configuration.body.string)
        textAccessibilityElement.accessibilityLabel = parts.filter { !$0.isEmpty }.joined(separator: "、")
        textAccessibilityElement.accessibilityFrameInContainerSpace = .null
        accessibilityElements = [textAccessibilityElement] + (mediaView.isHidden ? [] : [mediaView])
    }

    private lazy var textAccessibilityElement = UIAccessibilityElement(accessibilityContainer: self)

    override func layoutSubviews() {
        super.layoutSubviews()
        let textFrame = [boostLabel, nameRow, bodyLabel].filter { !$0.isHidden }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        textAccessibilityElement.accessibilityFrameInContainerSpace = textFrame.union(avatarView.frame)
    }
}
