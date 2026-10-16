import SciaCore
import UIKit

/// 投稿のセルの中身。左にアイコン、右に名前の行、本文、添付ファイルのサムネイルを並べる。
/// ブーストや固定された投稿なら、名前の上に、そのことを示す行を足す。
///
/// 名前の行の右端に時刻を置くため、`UIListContentConfiguration`の文字の枠を使わずに組む。
struct PostContentConfiguration: UIContentConfiguration {
    /// 名前の上の行。左のアイコンの列の右端に記号を置き、本文の列に、あればアイコンと文字を並べる。
    struct Context {
        let symbolName: String
        /// ブーストした人のアイコン。
        let avatar: AvatarView.Content?
        let text: NSAttributedString
        let accessibilityText: String
    }

    var context: Context?
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
    /// アイコンか名前の行がタップされたときに呼ぶ。投稿した人のプロフィールを開く。
    var onOpenAccount: (() -> Void)?
    /// 名前の上の行がタップされたときに呼ぶ。ブーストした人のプロフィールを開く。
    var onOpenContextAccount: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?

    /// 大きさと文字の見た目。
    struct Metrics {
        var margins: NSDirectionalEdgeInsets
        var avatarSize: CGFloat
        var boosterAvatarSize: CGFloat
        /// 名前が入りきらないときに、行末をぼかす幅。
        var nameFadeWidth: CGFloat
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
    /// 名前の上の行と名前の行のあいだの余白。
    private static let contextSpacing: CGFloat = 4

    private let avatarView: AvatarView
    private let contextIcon = UIImageView()
    private let contextAvatarView: AvatarView
    private let contextLabel = FadingLabel()
    private let nameLabels = [FadingLabel(), FadingLabel()]
    private let timeLabel = UILabel()
    private let nameRow = UIStackView()
    private let bodyLabel = LinkLabel()
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
        contextAvatarView = AvatarView(store: configuration.avatarImages)
        mediaView = MediaGridView(store: configuration.mediaImages)
        super.init(frame: .zero)
        addLayoutGuide(textGuide)
        configureSubviews()
        mediaView.onSelect = { [weak self] index in
            guard let self else { return }
            self.current.onSelectMedia?(index, self.mediaView)
        }
        mediaView.onReveal = { [weak self] in self?.current.onRevealMedia?() }
        bodyLabel.onTapLink = { [weak self] destination in self?.current.onOpenLink?(destination) }
        for view in [avatarView, nameRow] as [UIView] {
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openAccount)))
        }
        for view in [contextAvatarView, contextLabel] as [UIView] {
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openContextAccount)))
        }
        apply(configuration)
    }

    @objc private func openAccount() {
        current.onOpenAccount?()
    }

    @objc private func openContextAccount() {
        current.onOpenContextAccount?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSubviews() {
        contextIcon.tintColor = .secondaryLabel
        contextIcon.contentMode = .scaleAspectFit
        contextIcon.setContentHuggingPriority(.required, for: .horizontal)

        // 幅が足りなければ、2つ目（既定ではacct）から先に縮め、時刻は縮めない。
        for (index, label) in nameLabels.enumerated() {
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

        for view in [avatarView, contextIcon, contextAvatarView, contextLabel, nameRow, bodyLabel, mediaView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
    }

    private func apply(_ configuration: PostContentConfiguration) {
        current = configuration
        let metrics = configuration.metrics

        avatarView.apply(configuration.avatar)
        let context = configuration.context
        contextIcon.isHidden = context == nil
        contextAvatarView.isHidden = context?.avatar == nil
        contextLabel.isHidden = context == nil
        contextAvatarView.apply(context?.avatar)
        contextLabel.attributedText = context?.text
        contextLabel.fadeWidth = metrics.nameFadeWidth
        contextIcon.image = context.flatMap { UIImage(systemName: $0.symbolName) }
        contextIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: metrics.secondaryFont, scale: .small)

        for (index, label) in nameLabels.enumerated() {
            let text = configuration.nameParts.indices.contains(index) ? configuration.nameParts[index] : nil
            label.attributedText = text
            label.isHidden = text == nil
            label.fadeWidth = metrics.nameFadeWidth
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
        if let context = configuration.context {
            constraints += [
                contextLabel.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
                contextLabel.trailingAnchor.constraint(lessThanOrEqualTo: textGuide.trailingAnchor),
                // 記号はアイコンの列の右端に揃え、ブーストした人のアイコンと名前は本文の列に揃える。
                contextIcon.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor),
                contextIcon.centerYAnchor.constraint(equalTo: contextLabel.centerYAnchor),
                nameRow.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: Self.contextSpacing),
            ]
            if context.avatar != nil {
                constraints += [
                    contextAvatarView.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
                    contextAvatarView.centerYAnchor.constraint(equalTo: contextLabel.centerYAnchor),
                    contextAvatarView.widthAnchor.constraint(equalToConstant: metrics.boosterAvatarSize),
                    contextAvatarView.heightAnchor.constraint(equalToConstant: metrics.boosterAvatarSize),
                    contextLabel.leadingAnchor.constraint(equalTo: contextAvatarView.trailingAnchor, constant: 4),
                ]
            } else {
                constraints.append(contextLabel.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor))
            }
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

    /// 読み上げでは、名前の上の行、名前、時刻、本文の順に1つの要素として読む。サムネイルは別の要素のまま残す。
    private func updateAccessibility(for configuration: PostContentConfiguration) {
        var parts: [String] = []
        if let context = configuration.context {
            parts.append(context.accessibilityText)
        }
        parts += configuration.nameParts.map(\.string)
        parts.append(timeLabel.text ?? "")
        parts.append(configuration.body.string)
        textAccessibilityElement.accessibilityLabel = parts.filter { !$0.isEmpty }.joined(separator: "、")
        textAccessibilityElement.accessibilityCustomActions = Self.links(in: configuration.body).map { text, destination in
            UIAccessibilityCustomAction(name: text) { [weak self] _ in
                self?.current.onOpenLink?(destination)
                return true
            }
        }
        textAccessibilityElement.accessibilityFrameInContainerSpace = .null
        accessibilityElements = [textAccessibilityElement] + (mediaView.isHidden ? [] : [mediaView])
    }

    /// 本文のリンクを、文字と行き先の組で順に返す。書式で分かれた同じリンクはつなげる。押しても何もしないハッシュタグは除く。
    private static func links(in body: NSAttributedString) -> [(text: String, destination: RichText.LinkDestination)] {
        var result: [(text: String, destination: RichText.LinkDestination, end: Int)] = []
        body.enumerateAttribute(.linkDestination, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            guard let destination = value as? RichText.LinkDestination else { return }
            if case .hashtag = destination { return }
            let text = (body.string as NSString).substring(with: range)
            if let last = result.last, last.destination == destination, last.end == range.location {
                result[result.count - 1] = (last.text + text, destination, NSMaxRange(range))
            } else {
                result.append((text, destination, NSMaxRange(range)))
            }
        }
        return result.map { ($0.text, $0.destination) }
    }

    private lazy var textAccessibilityElement = UIAccessibilityElement(accessibilityContainer: self)

    override func layoutSubviews() {
        super.layoutSubviews()
        let textFrame = [contextLabel, nameRow, bodyLabel].filter { !$0.isHidden }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        textAccessibilityElement.accessibilityFrameInContainerSpace = textFrame.union(avatarView.frame)
    }
}
