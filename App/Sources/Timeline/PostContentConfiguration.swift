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
        /// 通知では種類ごとの色で描く。
        var symbolColor: UIColor = .secondaryLabel
        /// 通知の種類を示す記号。誰が何をしたかの行を主役にする通知の記号と縦に並ぶため、同じ大きさで描く。
        /// ブーストや固定の記号は、小さい文字の補足の行に釣り合うよう、文字より一段小さく描く。
        var isNotificationSymbol = false
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
    /// 注意書きがなければnil。
    var spoiler: PostBodyContent.Spoiler?
    var metrics: Metrics
    /// 添付ファイルがなければnil。
    var media: MediaGridView.Content?
    /// リンクカードを出さなければnil。
    var card: LinkCardView.Content?
    /// Xの投稿の囲み。あれば、リンクカードの代わりに出す。
    var xPost: XPostView.Content?
    /// 表示している投稿。ブーストなら、ブーストされた投稿。
    var statusID: Status.ID?
    let mediaImages: MediaImageStore
    let avatarImages: AvatarImageStore
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    /// 添付ファイルか、リンクカードの画像の、閲覧注意の覆いが押されたときに呼ぶ。覆いを外すのは置く側で、適用し直すまで見た目は変わらない。
    var onRevealMedia: (() -> Void)?
    var onToggleSpoiler: (() -> Void)?
    /// アイコンか名前の行がタップされたときに呼ぶ。投稿した人のプロフィールを開く。
    var onOpenAccount: (() -> Void)?
    /// 名前の上の行がタップされたときに呼ぶ。ブーストした人や、通知のもとになる操作をした人のプロフィールを開く。
    var onOpenContextAccount: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// リンクカードの画像がタップされたときに、ビューアを開閉する起点として、サムネイルを渡して呼ぶ。
    var onOpenLinkCardImage: ((LinkCardThumbnailView) -> Void)?
    /// Xの投稿の囲みのサムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectXPostMedia: ((Int, MediaGridView) -> Void)?

    /// 大きさと文字の見た目。
    struct Metrics {
        var margins: NSDirectionalEdgeInsets
        var avatarSize: CGFloat
        var boosterAvatarSize: CGFloat
        /// 名前が入りきらないときに、行末をぼかす幅。
        var nameFadeWidth: CGFloat
        /// 名前の上の行の記号と、その右の文字やアイコンとのすき間。
        var contextSymbolSpacing: CGFloat
        /// アイコンの列と、文字の列のあいだ。
        var avatarSpacing: CGFloat
        /// 名前の上の行と名前の行のあいだ。
        var contextSpacing: CGFloat
        /// 名前の行と本文のあいだ。
        var nameBodySpacing: CGFloat
        /// 本文と添付ファイルのあいだ。
        var bodyMediaSpacing: CGFloat
        /// 本文のない投稿で、名前の行と添付ファイルのあいだ。
        var nameMediaSpacing: CGFloat
        /// 本文か添付ファイルと、リンクカードのあいだ。
        var bodyLinkCardSpacing: CGFloat
        var nameFont: UIFont
        var secondaryFont: UIFont
        /// 通知の種類を示す記号の大きさを決める文字。誰が何をしたかの行を主役にする通知の記号と同じ大きさに揃えるため、
        /// 名前の上の行の小さい文字ではなく、本文と同じ大きさの文字にする。
        var notificationSymbolFont: UIFont
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

    private let avatarView: AvatarView
    private let contextIcon = UIImageView()
    private let contextAvatarView: AvatarView
    private let contextLabel = FadingLabel()
    private let nameLabels = [FadingLabel(), FadingLabel()]
    private let timeLabel = UILabel()
    private let nameRow = UIStackView()
    private let bodyView: PostBodyView
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
        bodyView.mediaGrid
    }

    /// 表示中の、Xの投稿の囲みのサムネイル。
    var xPostMediaGrid: MediaGridView? {
        bodyView.xPost?.mediaGrid
    }

    init(configuration: PostContentConfiguration) {
        current = configuration
        avatarView = AvatarView(store: configuration.avatarImages)
        contextAvatarView = AvatarView(store: configuration.avatarImages)
        bodyView = PostBodyView(mediaImages: configuration.mediaImages, avatarImages: configuration.avatarImages)
        super.init(frame: .zero)
        addLayoutGuide(textGuide)
        configureSubviews()
        bodyView.onSelectMedia = { [weak self] index, grid in self?.current.onSelectMedia?(index, grid) }
        bodyView.onRevealMedia = { [weak self] in self?.current.onRevealMedia?() }
        bodyView.onToggleSpoiler = { [weak self] in self?.current.onToggleSpoiler?() }
        bodyView.onOpenLink = { [weak self] destination in self?.current.onOpenLink?(destination) }
        bodyView.onOpenLinkCardImage = { [weak self] thumbnail in self?.current.onOpenLinkCardImage?(thumbnail) }
        bodyView.onSelectXPostMedia = { [weak self] index, grid in self?.current.onSelectXPostMedia?(index, grid) }
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

        for view in [avatarView, contextIcon, contextAvatarView, contextLabel, nameRow, bodyView] as [UIView] {
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
        let symbolConfiguration = if context?.isNotificationSymbol == true {
            UIImage.SymbolConfiguration(font: metrics.notificationSymbolFont)
        } else {
            UIImage.SymbolConfiguration(font: metrics.secondaryFont, scale: .small)
        }
        // ベースラインの位置を読むため、大きさの設定を画像そのものに当てておく。
        contextIcon.image = context.flatMap { UIImage(systemName: $0.symbolName, withConfiguration: symbolConfiguration) }
        contextIcon.tintColor = context?.symbolColor ?? .secondaryLabel

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

        bodyView.apply(PostBodyContent(
            spoiler: configuration.spoiler,
            text: configuration.body,
            media: configuration.media,
            mediaSpacing: metrics.bodyMediaSpacing,
            card: configuration.card,
            cardSpacing: metrics.bodyLinkCardSpacing,
            xPost: configuration.xPost,
            statusID: configuration.statusID
        ))
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
            textGuide.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: metrics.avatarSpacing),
            textGuide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.trailing),
            nameRow.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
            nameRow.trailingAnchor.constraint(equalTo: textGuide.trailingAnchor),
            // 間隔は、名前の字面の下端から測る。
            bodyView.topAnchor.constraint(
                equalTo: nameLabels[0].lastBaselineAnchor,
                constant: (bodyView.startsWithMedia ? metrics.nameMediaSpacing : metrics.nameBodySpacing) + metrics.nameFont.pointSize * PostBodyView.emBoxDescent
            ),
            bodyView.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: textGuide.trailingAnchor),
            // 本文が短くても、アイコンが下の余白に食い込まないようにする。
            bottomAnchor.constraint(greaterThanOrEqualTo: avatarView.bottomAnchor, constant: margins.bottom),
        ]
        if let context = configuration.context {
            constraints += [
                contextLabel.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
                contextLabel.trailingAnchor.constraint(lessThanOrEqualTo: textGuide.trailingAnchor),
                // 記号は本文の列から決まった幅だけ離して置き、ブーストした人のアイコンと名前は本文の列に揃える。
                // アイコンの列の右端に揃えると、細い記号では文字とのあいだが間延びして見えるため。
                contextIcon.trailingAnchor.constraint(equalTo: textGuide.leadingAnchor, constant: -metrics.contextSymbolSpacing),
                Self.symbolVerticalConstraint(contextIcon, beside: contextLabel, onBaseline: context.isNotificationSymbol),
                nameRow.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: metrics.contextSpacing),
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
        let contentBottom = bodyView.bottomAnchor
        // アイコンの方が下まで届くときは、等しさを諦めてアイコンの下に余白を取る。
        // 文字のラベルの縦のhugging（defaultLow）より弱くし、余りの高さでラベルを伸ばさずに、本文の下に空きを置く。
        // UILabelは伸ばされた枠の上下中央に文字を描くため、伸ばすと本文が名前の行から下にずれる。
        let fitsContent = bottomAnchor.constraint(equalTo: contentBottom, constant: margins.bottom)
        fitsContent.priority = .defaultLow - 1
        constraints += [
            bottomAnchor.constraint(greaterThanOrEqualTo: contentBottom, constant: margins.bottom),
            fitsContent,
        ]
        variableConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    /// 記号を、右の文字の行に対して縦に置く制約。
    /// 通知の種類の記号は文字より大きいため、中心で揃えると上下にはみ出して浮いて見える。文字のベースラインに乗せ、はみ出す分を上にだけ出す。
    /// ブーストや固定の記号は文字と同じくらいの大きさなので、中心で揃える。
    static func symbolVerticalConstraint(_ symbol: UIImageView, beside label: UILabel, onBaseline: Bool) -> NSLayoutConstraint {
        guard onBaseline, let image = symbol.image else {
            return symbol.centerYAnchor.constraint(equalTo: label.centerYAnchor)
        }
        return symbol.bottomAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: Self.baselineToAlignmentBottom(of: image))
    }

    /// 記号の画像の、ベースラインから、Auto Layoutで揃える枠の下端までの距離。下端がベースラインより下にあれば正の値。
    /// `baselineOffsetFromBottom`は画像の下端から測るが、`bottomAnchor`は画像の余白を除いた枠の下端なので、その差を引く。
    static func baselineToAlignmentBottom(of image: UIImage) -> CGFloat {
        (image.baselineOffsetFromBottom ?? 0) - image.alignmentRectInsets.bottom
    }

    /// 読み上げでは、名前の上の行、名前、時刻、本文の順に1つの要素として読む。サムネイルとリンクカードは別の要素のまま残す。
    private func updateAccessibility(for configuration: PostContentConfiguration) {
        var parts: [String] = []
        if let context = configuration.context {
            parts.append(context.accessibilityText)
        }
        parts += configuration.nameParts.map(\.string)
        parts.append(timeLabel.text ?? "")
        parts.append(bodyView.accessibilityText)
        textAccessibilityElement.accessibilityLabel = parts.filter { !$0.isEmpty }.joined(separator: "、")
        textAccessibilityElement.accessibilityCustomActions = [bodyView.spoilerAccessibilityAction()].compactMap(\.self) + bodyView.linkAccessibilityActions()
        // 枠はlayoutSubviewsで決める。大きさの変わらない描き直し（絵文字の画像が届いたときなど）では並べ直しが起きないため、枠を空にせず、並べ直しを頼む。
        // 空にすると、次に並べ直すまで、VoiceOverで指でなぞってもこの行に止まらない。
        setNeedsLayout()
        accessibilityElements = [textAccessibilityElement] + [bodyView.mediaGrid, bodyView.linkCard, bodyView.xPost].compactMap(\.self)
    }

    private lazy var textAccessibilityElement = UIAccessibilityElement(accessibilityContainer: self)

    override func layoutSubviews() {
        super.layoutSubviews()
        // 本文の枠は中身の部品の中で決まるため、先に並べておく。
        bodyView.layoutIfNeeded()
        let bodyTextFrame = bodyView.convert(bodyView.textFrame, to: self)
        let textFrame = [contextLabel, nameRow].filter { !$0.isHidden }.map(\.frame).reduce(bodyTextFrame) { $0.union($1) }
        textAccessibilityElement.accessibilityFrameInContainerSpace = textFrame.union(avatarView.frame)
    }
}
