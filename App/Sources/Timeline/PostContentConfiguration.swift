import SciaCore
import UIKit

/// 投稿のセルの中身。左にアイコン、右に名前の行、本文、添付ファイルのサムネイルを並べる。
/// ブーストや固定された投稿、返信なら、名前の上に、そのことを示す行を足す。
/// 返信と返信先が隣り合う行では、アイコン同士を縦の線でつなぐ。
///
/// 名前の行の右端に時刻を置くため、`UIListContentConfiguration`の文字の枠を使わずに組む。
struct PostContentConfiguration: UIContentConfiguration {
    /// 名前の上の行。左のアイコンの列の右端に記号を置き、本文の列に、あればアイコンと文字を並べる。
    struct Context {
        let symbolName: String
        /// 通知では種類ごとの色で描く。
        var symbolColor: UIColor = .secondaryLabel
        /// 通知の種類を示す記号の大きさを決める文字。通知の種類を示す記号でなければnil。
        /// 通知の記号は、誰が何をしたかの行を主役にする通知の記号と縦に並ぶため、その行の文字で描き、文字の1行目のベースラインに乗せる。
        /// ブーストや固定の記号は、小さい文字の補足の行に釣り合うよう、文字より一段小さく描く。
        var notificationSymbolFont: UIFont?
        /// ブーストした人のアイコン。
        let avatar: AvatarView.Content?
        let text: NSAttributedString
        /// `text`のうち、名前の後ろに添える部分（ハンドルなど）。「投稿の見た目」のプレビューで、名前の部分と分けて場所を示すのに使う。
        var secondaryRange: NSRange?
        let accessibilityText: String
        /// 押すと開くプロフィールの人の名前。VoiceOverの、プロフィールを開く操作の名前に使う。人を指さない行ではnil。
        var accountName: String?
        /// 押すと`onOpenContextAccount`を呼ぶ。返信のラベルは押せる見た目にせず、押下を行に渡してスレッドを開かせるため、受けない。
        var opensAccount = true
    }

    var context: Context?
    /// 隣の行とアイコン同士を線でつなぐか。
    var replyConnection = ReplyConnection()
    /// 返信をつなぐ線を描く。描かなくても、つながりは区切り線の有無などに使う。
    var showsReplyLines = true
    /// 名前の行の右端に時刻を出す。出さなくても、読み上げでは読む。
    var showsTime = true
    /// ブーストされた投稿。「投稿の見た目」のプレビューで、ブーストした人の行を探すのに使う。
    var isBoost = false
    /// 返信。返信のラベルを出さない設定でも立てる。「投稿の見た目」のプレビューで、ラベルの場所を探すのに使う。
    var isReply = false
    /// リンクカードを出さない設定で、出すはずだったリンクカードを出していない。「投稿の見た目」のプレビューで、カードの場所を示すのに使う。
    var hasHiddenLinkCard = false
    var avatar: AvatarView.Content
    /// 名前の行に並べる文字。先頭を目立たせ、2つ目は控えめに描く。
    var nameParts: [NSAttributedString]
    /// 投稿した人の名前。名前の行の書き方によらず、VoiceOverの、プロフィールを開く操作の名前に使う。
    var authorName: String
    var createdAt: Date
    /// 投稿が編集されていれば、時刻の前にアイコンを付ける。時刻は編集した時刻ではなく、投稿した時刻のまま。
    var isEdited = false
    /// 公開以外なら、時刻と編集済みのアイコンの前に、投稿欄で選ぶときと同じ記号を付ける。
    var visibility: Status.Visibility = .public
    /// 公開範囲の記号と、編集済みの「*」を出すか。出さなくても、読み上げでは読む。
    var showsVisibilitySymbol = true
    var showsEditedMark = true
    var timeStyle: StatusTimeStyle
    var body: NSAttributedString
    /// 注意書きがなければnil。
    var spoiler: PostBodyContent.Spoiler?
    var metrics: Metrics
    /// 添付ファイルがなければnil。
    var media: MediaGridView.Content?
    /// 投票がなければnil。
    var poll: PollView.Content?
    /// リンクカードを出さなければnil。
    var card: LinkCardView.Content?
    /// 引用かXの投稿の囲み。あれば、リンクカードの代わりに出す。
    var embed: EmbeddedPostView.Content?
    /// 表示している投稿。ブーストなら、ブーストされた投稿。
    var statusID: Status.ID?
    /// 本文のハッシュタグのメニューの「ユーザーの投稿」で開くユーザー。表示している投稿を投稿した人。
    var hashtagAccount: Account?
    /// 自分の投稿が自分のフィルターに一致していることを示す1行。一致していなければnil。
    var filterNote: NSAttributedString?
    /// お気に入りとブーストをしたことを示す、行の下の端の光。
    var reactionGlow: ReactionGlow?
    let mediaImages: MediaImageStore
    let avatarImages: AvatarImageStore
    /// 名前、ブーストした人の行、注意書き、本文のアニメーションするカスタム絵文字を動かすときに、アニメーション版を読み込むストア。nilなら動かさない。
    var emojiImages: EmojiImageStore?
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    /// 添付ファイルか、リンクカードの画像の、閲覧注意のぼかしが押されたときに呼ぶ。ぼかしを外すのは置く側で、適用し直すまで見た目は変わらない。
    var onRevealMedia: (() -> Void)?
    var onToggleSpoiler: (() -> Void)?
    /// アイコンがタップされたときに呼ぶ。投稿した人のプロフィールを開く。
    var onOpenAccount: (() -> Void)?
    /// 名前の上の行がタップされたときに呼ぶ。ブーストした人や、通知のもとになる操作をした人のプロフィールを開く。
    var onOpenContextAccount: (() -> Void)?
    /// アイコンのタップと長押し。渡すと、タップは`onOpenAccount`の代わりにこれで行い、長押しではその人のユーザーのメニューか、選んだ操作を行う。
    /// 決まりはdocs/object-actions.mdにある。読み上げの操作は、`onOpenAccount`のまま。
    var authorTarget: (any ObjectActionTarget)?
    /// 名前の上の行のタップと長押し。`authorTarget`と同じ。
    var contextTarget: (any ObjectActionTarget)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// リンクカードの画像がタップされたときに、ビューアを開閉する起点として、サムネイルを渡して呼ぶ。
    var onOpenLinkCardImage: ((LinkCardThumbnailView) -> Void)?
    /// 囲みの押下と、囲みの中の部品の押下で呼ぶ処理。
    var embedActions = EmbedActions()
    /// リンクカードのタップと長押し。決まりはdocs/object-actions.mdにある。
    var linkCardTarget: (any ObjectActionTarget)?
    /// 投票の選択肢やボタンが押されたときに呼ぶ。
    var onPollAction: ((PollView.Action) -> Void)?

    /// 大きさと文字の見た目。
    struct Metrics {
        var margins: NSDirectionalEdgeInsets
        var avatarSize: CGFloat
        var boosterAvatarSize: CGFloat
        /// 名前が入りきらないときに、行末をぼかす幅。
        var nameFadeWidth: CGFloat
        /// 名前の上の行の記号と、その右の文字やアイコンとのすき間。
        var contextSymbolSpacing: CGFloat
        /// 名前の上の行の、ブーストした人のアイコンと文字のすき間。
        var contextAvatarTextSpacing: CGFloat
        /// アイコンの列と、文字の列のあいだ。
        var avatarSpacing: CGFloat
        /// 名前の上の行と名前の行のあいだ。
        var contextSpacing: CGFloat
        /// 返信をつなぐ線の太さ。
        var replyLineWidth: CGFloat
        /// 返信をつなぐ線と、アイコンのあいだのすき間。
        var replyLineGap: CGFloat
        /// 名前の行と本文のあいだ。
        var nameBodySpacing: CGFloat
        /// 本文と添付ファイルのあいだ。
        var bodyMediaSpacing: CGFloat
        /// 本文のない投稿で、名前の行と添付ファイルのあいだ。
        var nameMediaSpacing: CGFloat
        /// 本文か添付ファイルと、リンクカードのあいだ。
        var bodyLinkCardSpacing: CGFloat
        /// 本文と投票のあいだ。
        var bodyPollSpacing: CGFloat
        /// 名前の行で、太字の部分と後ろに添える部分のすき間。
        var namePartsSpacing: CGFloat
        /// 名前と時刻の最小のすき間。
        var nameTimeSpacing: CGFloat
        /// 名前の行で、太字で描く前の部分の文字。
        var nameFont: UIFont
        var timeFont: UIFont
        /// 名前の上の行の文字。記号の大きさもこれに合わせる。
        var contextFont: UIFont
        /// 時刻の前の公開範囲の記号と、時刻のすき間。
        var visibilitySymbolSpacing: CGFloat = 4
        /// 時刻の前の編集済みの「*」と、時刻のすき間。
        var editedMarkSpacing: CGFloat = 0
        /// 本文などと、自分のフィルターに一致したことを示す注記のあいだ。
        var filterNoteSpacing: CGFloat = 10
        /// 名前の上の行の先頭に、ブーストや返信を示す記号を出す。
        var showsContextSymbol = true
        /// 本文か添付ファイルと、囲みのあいだ。
        var bodyEmbedSpacing: CGFloat = 10
    }

    func makeContentView() -> any UIView & UIContentView {
        PostContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> PostContentConfiguration {
        self
    }

    /// `now`の時点での時刻の表記。
    func timeText(now: Date) -> String {
        let text = StatusTimestamp.text(for: createdAt, now: now, style: timeStyle)
        return isEdited && showsEditedMark ? "*\(text)" : text
    }

    /// 時刻の前に付ける公開範囲の記号。公開ならnil。
    var visibilitySymbolName: String? {
        visibility == .public || !showsVisibilitySymbol ? nil : VisibilityOption(visibility).symbolName
    }

    /// 読み上げる時刻。アイコンは読まず、言葉にする。
    func timeAccessibilityText(now: Date) -> String {
        var text = StatusTimestamp.accessibilityText(for: createdAt, now: now, style: timeStyle)
        if isEdited {
            text = "編集済み、\(text)"
        }
        if visibility != .public {
            text = "\(VisibilityOption(visibility).title)、\(text)"
        }
        return text
    }
}

final class PostContentView: UIView, UIContentView {
    /// 今の日付。テストでは決まった日付に差し替える。
    var now: () -> Date = AppDependencies.now

    private let avatarView: AvatarView
    private let contextIcon = UIImageView()
    private let contextAvatarView: AvatarView
    private let contextLabel = FadingLabel()
    /// アイコンと名前の上の行の、長押しのメニューと長押しの操作。
    private var authorInteraction: ObjectInteraction?
    private var contextInteractions: [ObjectInteraction] = []
    private let nameLabels = [FadingLabel(), FadingLabel()]
    private let timeLabel = UILabel()
    /// 描いている時刻の表記。記号を除いた文字で、書き直すかどうかを比べる。
    private var timeText = ""
    private let nameRow = UIStackView()
    private let bodyView: PostBodyView
    private let textGuide = UILayoutGuide()
    /// 名前の最後のベースラインの位置。名前の行の下のすき間は字面から測るので、「投稿の見た目」のプレビューで字面の下端を求めるのに使う。
    private let nameBaselineGuide = UILayoutGuide()
    /// 名前の上の行の高さ。文字とブーストした人のアイコンの高いほうにする。アイコンを大きくしても、名前の行に重ならないようにするため。
    private let contextGuide = UILayoutGuide()
    private let reactionGlowView = ReactionGlowView()
    /// アイコンから上の行へ伸ばす線と、下の行へ伸ばす線。高さに影響しないよう、制約を使わず並べるたびに枠を決める。
    private let replyLineAbove = UIView()
    private let replyLineBelow = UIView()
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

    /// 投稿の中身。「テキストを選択」で本文を選べる状態にするときに使う。
    var postBody: PostBodyView {
        bodyView
    }

    /// 描いている投票の見え方。投票がなければnil。
    var pollDisplay: PollDisplay? {
        current.poll?.display
    }

    /// 表示中の、引用かXの投稿の囲み。
    var embed: EmbeddedPostView? {
        bodyView.embed
    }

    /// 表示中の、囲みのサムネイル。
    var embedMediaGrid: MediaGridView? {
        bodyView.embed?.mediaGrid
    }

    /// 名前の行の上に置いた、ブーストした人や返信先の行の分の高さ。置いていなければ0。
    /// スレッドを開くとき、一覧の行とスレッドの行で、この行の有無が違っても投稿の中身の位置を合わせるのに使う。
    var contextHeight: CGFloat {
        guard current.context != nil else { return 0 }
        layoutIfNeeded()
        // 名前の行は、大きい絵文字があると上の空きの分だけ上に置くので、アイコンの上端から測る。
        return avatarView.frame.minY - current.metrics.margins.top
    }

    init(configuration: PostContentConfiguration) {
        current = configuration
        avatarView = AvatarView(store: configuration.avatarImages)
        contextAvatarView = AvatarView(store: configuration.avatarImages)
        bodyView = PostBodyView(mediaImages: configuration.mediaImages, avatarImages: configuration.avatarImages)
        super.init(frame: .zero)
        addLayoutGuide(textGuide)
        addLayoutGuide(nameBaselineGuide)
        addLayoutGuide(contextGuide)
        configureSubviews()
        bodyView.onSelectMedia = { [weak self] index, grid in self?.current.onSelectMedia?(index, grid) }
        bodyView.onRevealMedia = { [weak self] in self?.current.onRevealMedia?() }
        bodyView.onToggleSpoiler = { [weak self] in self?.current.onToggleSpoiler?() }
        bodyView.onOpenLink = { [weak self] destination in self?.current.onOpenLink?(destination) }
        bodyView.onTextSelectionChange = { [weak self] in
            guard let self else { return }
            updateAccessibility(for: current)
            if let textView = bodyView.selectionTextView {
                UIAccessibility.post(notification: .layoutChanged, argument: textView)
            }
        }
        bodyView.onOpenLinkCardImage = { [weak self] thumbnail in self?.current.onOpenLinkCardImage?(thumbnail) }
        bodyView.onPollAction = { [weak self] action in self?.current.onPollAction?(action) }
        // 名前の行は押下を受けず、行全体の押下に渡す。受けると、1行の投稿では行を押せる場所が本文の1行ほどしか残らない。
        avatarView.isUserInteractionEnabled = true
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))
        authorInteraction = ObjectInteraction(on: avatarView, tapsSelf: false, lift: .shape)
        for view in [contextAvatarView, contextLabel] as [UIView] {
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(contextTapped)))
            contextInteractions.append(ObjectInteraction(on: view, tapsSelf: false, lift: view === contextLabel ? .none : .shape))
        }
        apply(configuration)
    }

    @objc private func avatarTapped(_ gesture: UITapGestureRecognizer) {
        guard let target = current.authorTarget, let view = gesture.view else {
            openAccount()
            return
        }
        target.perform(.tap, in: view, at: gesture.location(in: view))
    }

    @objc private func contextTapped(_ gesture: UITapGestureRecognizer) {
        guard let target = current.contextTarget, let view = gesture.view else {
            openContextAccount()
            return
        }
        target.perform(.tap, in: view, at: gesture.location(in: view))
    }

    private func openAccount() {
        current.onOpenAccount?()
    }

    private func openContextAccount() {
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
        // すき間は、名前の表記と設定に合わせて、適用のたびに決める。時刻を右端に寄せるため、2つ目の名前が余りの幅を受け持つ。
        // ベースラインで揃えたスタックは、上下の端が中の文字より外にあればよいという制約になり、高さが決まらない。
        // セルは大きな高さを目安に測るため、何もしないと行がその高さまで伸びる。文字が収まる最小の高さに寄せる。
        let compactNameRow = nameRow.heightAnchor.constraint(equalToConstant: 0)
        compactNameRow.priority = .defaultLow
        compactNameRow.isActive = true

        for view in [avatarView, contextIcon, contextAvatarView, contextLabel, nameRow, bodyView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            nameBaselineGuide.topAnchor.constraint(equalTo: nameLabels[0].lastBaselineAnchor),
            nameBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
        ])
        for line in [replyLineAbove, replyLineBelow] {
            line.backgroundColor = .tertiaryLabel
            line.isUserInteractionEnabled = false
            insertSubview(line, at: 0)
        }
        reactionGlowView.install(in: self)
    }

    private func apply(_ configuration: PostContentConfiguration) {
        current = configuration
        let metrics = configuration.metrics

        avatarView.apply(configuration.avatar)
        authorInteraction?.target = configuration.authorTarget
        for interaction in contextInteractions {
            interaction.target = configuration.context?.opensAccount == true ? configuration.contextTarget : nil
        }
        let context = configuration.context
        contextIcon.isHidden = context == nil || !metrics.showsContextSymbol
        contextAvatarView.isHidden = context?.avatar == nil
        contextLabel.isHidden = context == nil
        contextLabel.isUserInteractionEnabled = context?.opensAccount ?? false
        contextAvatarView.isUserInteractionEnabled = context?.opensAccount ?? false
        contextAvatarView.apply(context?.avatar)
        contextLabel.emojiImages = configuration.emojiImages
        contextLabel.attributedText = context?.text
        contextLabel.fadeWidth = metrics.nameFadeWidth
        let symbolConfiguration = if let font = context?.notificationSymbolFont {
            UIImage.SymbolConfiguration(font: font)
        } else {
            UIImage.SymbolConfiguration(font: metrics.contextFont, scale: .small)
        }
        // ベースラインの位置を読むため、大きさの設定を画像そのものに当てておく。
        contextIcon.image = context.flatMap { UIImage(systemName: $0.symbolName, withConfiguration: symbolConfiguration) }
        contextIcon.tintColor = context?.symbolColor ?? .secondaryLabel

        for (index, label) in nameLabels.enumerated() {
            let text = configuration.nameParts.indices.contains(index) ? configuration.nameParts[index] : nil
            label.emojiImages = configuration.emojiImages
            label.attributedText = text
            label.isHidden = text == nil
            label.fadeWidth = metrics.nameFadeWidth
        }
        // 2つ目がないときは、1つ目が余りの幅を受け持つ。
        nameLabels[0].setContentHuggingPriority(configuration.nameParts.count > 1 ? .required : .defaultLow, for: .horizontal)
        // 時刻の前のすき間は、出している最後の名前のあとに取る。隠したラベルのあとのすき間は使われないため。
        nameRow.spacing = metrics.namePartsSpacing
        let lastName = nameLabels[min(max(configuration.nameParts.count, 1), nameLabels.count) - 1]
        for label in nameLabels {
            nameRow.setCustomSpacing(label === lastName ? metrics.nameTimeSpacing : metrics.namePartsSpacing, after: label)
        }
        timeLabel.font = metrics.timeFont
        timeText = configuration.timeText(now: now())
        timeLabel.attributedText = timeAttributedText(timeText, for: configuration)
        timeLabel.isHidden = !configuration.showsTime

        bodyView.emojiImages = configuration.emojiImages
        bodyView.embedActions = configuration.embedActions
        bodyView.cardTarget = configuration.linkCardTarget
        bodyView.apply(PostBodyContent(
            spoiler: configuration.spoiler,
            text: configuration.body,
            media: configuration.media,
            mediaSpacing: metrics.bodyMediaSpacing,
            poll: configuration.poll,
            pollSpacing: metrics.bodyPollSpacing,
            card: configuration.card,
            cardSpacing: metrics.bodyLinkCardSpacing,
            embed: configuration.embed,
            embedSpacing: metrics.bodyEmbedSpacing,
            statusID: configuration.statusID,
            hashtagAccount: configuration.hashtagAccount,
            filterNote: configuration.filterNote,
            // リンクカードと同じく、本文から少し離した補足として置く。
            filterNoteSpacing: metrics.filterNoteSpacing
        ))
        reactionGlowView.apply(configuration.reactionGlow)
        replyLineAbove.isHidden = !(configuration.replyConnection.above && configuration.showsReplyLines)
        replyLineBelow.isHidden = !(configuration.replyConnection.below && configuration.showsReplyLines)
        setNeedsLayout()
        updateConstraints(for: configuration)
        updateAccessibility(for: configuration)
    }

    /// 「投稿の見た目」のプレビューで、部品の場所を示すための枠。このビューの座標で返す。
    func previewFrames() -> AppearancePreviewFrames {
        let margins = current.metrics.margins
        var frames: AppearancePreviewFrames = [
            .rowPaddingTop: [CGRect(x: 0, y: 0, width: bounds.width, height: margins.top)],
            .rowPaddingBottom: [CGRect(x: 0, y: bounds.height - margins.bottom, width: bounds.width, height: margins.bottom)],
            .rowPaddingLeading: [CGRect(x: 0, y: 0, width: margins.leading, height: bounds.height)],
            .rowPaddingTrailing: [CGRect(x: bounds.width - margins.trailing, y: 0, width: margins.trailing, height: bounds.height)],
            .contextSymbol: contextIcon.image == nil ? nil : contextIcon.previewFrame(in: self),
            .contextAvatar: contextAvatarView.previewFrame(in: self),
            .contextLine: textExtent(of: contextLabel),
            .avatar: avatarView.previewFrame(in: self),
            .replyLineBelow: replyLineBelow.previewFrame(in: self),
            .nameRow: nameRow.previewFrame(in: self),
            .nameGlyphs: nameGlyphsFrame(),
            .namePrimary: textExtent(of: nameLabels[0]),
            .nameSecondary: textExtent(of: nameLabels[1]),
            .time: timeLabel.previewFrame(in: self),
            .visibilityTime: current.visibility == .public ? nil : timeLabel.previewFrame(in: self),
            .editedTime: current.isEdited ? timeLabel.previewFrame(in: self) : nil,
            .boostLine: current.isBoost ? textExtent(of: contextLabel) : nil,
            .replyLabel: current.isReply && current.context != nil ? textExtent(of: contextLabel) : nil,
            .connectedAvatar: current.replyConnection.below ? avatarView.previewFrame(in: self) : nil,
            .nameFade: nameFadeFrames(),
            .nameCustomEmojis: nameCustomEmojiFrames(),
            .nameUnicodeEmojis: nameUnicodeEmojiFrames(),
            .nameTimeMinGap: nameTimeMinGapFrame(),
        ].compactMapValues(\.self)
        frames.merge(slotPreviewFrames()) { $1 }
        frames.merge(timePreviewFrames()) { $1 }
        if let avatar = avatarView.previewFrame(in: self)?.first {
            let radius = current.avatar.shape == .circle ? avatar.width / 2 : avatar.width * current.avatar.cornerRatio
            frames[.avatarCorners] = AppearanceHighlight.cornerSquares(of: avatar, radius: radius)
        }
        frames.merge(contextTextPreviewFrames()) { $1 }
        frames.merge(bodyView.previewFrames(in: self)) { $1 }
        frames.merge(reactionGlowView.previewFrames(in: self)) { $1 }
        return frames
    }

    /// ラベルの、文字のある部分の枠。名前の行のラベルは余った幅を受け持つので、枠には文字のない部分が含まれる。
    private func textExtent(of label: UILabel) -> [CGRect]? {
        guard var frame = label.previewFrame(in: self)?.first else { return nil }
        frame.size.width = min(frame.width, ceil(label.intrinsicContentSize.width))
        return [frame]
    }

    /// 名前が入りきらず時刻に詰まっているときの、最後の名前と時刻のすき間。名前が短ければ、最小のすき間より広く空くのでnil。
    private func nameTimeMinGapFrame() -> [CGRect]? {
        guard !timeLabel.isHidden,
              // 押し縮められて幅0になったハンドルも、時刻との最小のすき間はそのラベルのあとに取るので、幅によらず最後のラベルから測る。
              let last = nameLabels.last(where: { !$0.isHidden }),
              nameLabels.contains(where: { !$0.isHidden && $0.intrinsicContentSize.width > $0.bounds.width + 0.5 })
        else { return nil }
        let name = last.convert(last.bounds, to: self)
        let time = timeLabel.convert(timeLabel.bounds, to: self)
        let minY = min(name.minY, time.minY)
        return [CGRect(x: name.maxX, y: minY, width: max(time.minX - name.maxX, 0), height: max(name.maxY, time.maxY) - minY)]
    }

    /// 名前の行と名前の上の行の、カスタム絵文字の枠。
    private func nameCustomEmojiFrames() -> [CGRect]? {
        let frames = (nameLabels + [contextLabel]).filter { !$0.isHidden }.flatMap { label in
            label.previewCustomEmojiFrames().map { label.convert($0, to: self) }
        }
        return frames.isEmpty ? nil : frames
    }

    /// 名前の行と名前の上の行の、大きさを変えた絵文字の枠。
    private func nameUnicodeEmojiFrames() -> [CGRect]? {
        let frames = (nameLabels + [contextLabel]).filter { !$0.isHidden }.flatMap { label in
            label.previewUnicodeEmojiFrames().map { label.convert($0, to: self) }
        }
        return frames.isEmpty ? nil : frames
    }

    /// 入りきらずに行末をぼかしている名前やブーストした人の行の、ぼかしている部分。
    private func nameFadeFrames() -> [CGRect]? {
        let fades = (nameLabels + [contextLabel]).compactMap { label -> CGRect? in
            // 幅のないラベル（長い名前に押し出されたハンドルなど）は、ぼかしを描いていないので除く。
            guard let frame = label.previewFrame(in: self)?.first, frame.width >= 1, label.intrinsicContentSize.width > frame.width + 0.5 else { return nil }
            let width = min(label.fadeWidth, frame.width)
            return CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
        }
        return fades.isEmpty ? nil : fades
    }

    /// 消せる部品の場所。出ていればその部品の枠を、消していれば部品があった位置に細い枠を返す。消したときに、どこから消えたかを示すため。
    private func slotPreviewFrames() -> AppearancePreviewFrames {
        func line(x: CGFloat, y: CGFloat, height: CGFloat) -> [CGRect] {
            [CGRect(x: x - AppearanceHighlight.minimumGapThickness / 2, y: y, width: AppearanceHighlight.minimumGapThickness, height: height)]
        }
        func bar(x: CGFloat, y: CGFloat, width: CGFloat) -> [CGRect] {
            [CGRect(x: x, y: y - AppearanceHighlight.minimumGapThickness / 2, width: width, height: AppearanceHighlight.minimumGapThickness)]
        }
        var frames: AppearancePreviewFrames = [:]
        let row = nameRow.frame
        if current.context != nil {
            // 記号は消しても、置く位置の制約は残っているので、枠は並べた位置のまま。
            frames[.contextSymbolSlot] = [contextIcon.frame]
        }
        if current.isBoost {
            frames[.boosterAvatarSlot] = contextAvatarView.isHidden ? line(x: contextLabel.frame.minX, y: contextLabel.frame.minY, height: contextLabel.frame.height) : [contextAvatarView.frame]
        }
        if current.isReply {
            frames[.replyLabelSlot] = current.context == nil ? bar(x: row.minX, y: row.minY - 1, width: row.width) : textExtent(of: contextLabel)
        }
        frames[.timeSlot] = timeLabel.isHidden ? line(x: row.maxX, y: row.minY, height: row.height) : [timeLabel.convert(timeLabel.bounds, to: self)]
        if current.replyConnection.below {
            frames[.replyLineSlot] = replyLineBelow.isHidden ? line(x: avatarView.frame.midX, y: avatarView.frame.maxY, height: bounds.maxY - avatarView.frame.maxY) : [replyLineBelow.frame]
        }
        // 返信でつながった行と光っている行には、一覧で区切り線を引かないので、示さない。
        if !current.replyConnection.below, current.reactionGlow?.isLit != true {
            frames[.separatorLine] = bar(x: 0, y: bounds.maxY - 1, width: bounds.width)
        }
        if current.hasHiddenLinkCard {
            frames[.cardSlot] = bar(x: bodyView.frame.minX, y: bodyView.frame.maxY, width: bodyView.frame.width)
        }
        return frames
    }

    /// 時刻の中の、公開範囲の記号と「*」と、それぞれと時刻のすき間。時刻のラベルは文字の幅に合わせて置くので、左端から測る。
    /// すき間は設定の値ではなく、描く文字列の幅から測る。すき間が効いていなければ、それが帯の太さに出るようにするため。
    private func timePreviewFrames() -> AppearancePreviewFrames {
        guard !timeLabel.isHidden, let text = timeLabel.attributedText, text.length > 0 else { return [:] }
        // 時刻のラベルは名前の行の中にあるので、この行の座標に直す。
        let label = timeLabel.convert(timeLabel.bounds, to: self)
        func width(upTo end: Int) -> CGFloat {
            ceil(text.attributedSubstring(from: NSRange(location: 0, length: min(end, text.length))).size().width)
        }
        func band(from start: CGFloat, to end: CGFloat) -> [CGRect] {
            [CGRect(x: label.minX + start, y: label.minY, width: max(end - start, 0), height: label.height)]
        }
        var frames: AppearancePreviewFrames = [:]
        var index = 0
        if current.visibility != .public {
            if current.visibilitySymbolName != nil {
                // 記号の画像、すき間を作る空白の順に並ぶ。
                let symbolEnd = width(upTo: 1)
                frames[.visibilitySymbol] = band(from: 0, to: symbolEnd)
                frames[.visibilitySymbolGap] = band(from: symbolEnd, to: width(upTo: 2))
                index = 2
            } else {
                frames[.visibilitySymbol] = [CGRect(x: label.minX - 1, y: label.minY, width: 2, height: label.height)]
            }
        }
        if current.isEdited {
            let start = width(upTo: index)
            if current.showsEditedMark {
                let markWidth = ceil(("*" as NSString).size(withAttributes: [.font: current.metrics.timeFont]).width)
                frames[.editedMark] = band(from: start, to: start + markWidth)
                frames[.editedMarkGap] = band(from: start + markWidth, to: width(upTo: index + 1))
            } else {
                frames[.editedMark] = [CGRect(x: label.minX + start - 1, y: label.minY, width: 2, height: label.height)]
            }
        }
        return frames
    }

    /// 名前の字面の枠。上端と下端は、ベースラインからem枠で測る。下端は、大きくした絵文字が下へ伸びていればその下端にする。並びも同じ測り方で、本文やメディアとのすき間を取っている。
    private func nameGlyphsFrame() -> [CGRect]? {
        guard let row = nameRow.previewFrame(in: self)?.first else { return nil }
        let baseline = nameBaselineGuide.layoutFrame.minY
        let top = baseline - Self.largestNamePointSize(of: current) * PostBodyView.emBoxAscent
        return [CGRect(x: row.minX, y: top, width: row.width, height: baseline + Self.nameBottomInset(of: current) - top)]
    }

    /// 名前の上の行の文字を、名前の部分と添える部分に分けた枠。添える部分がなければ、全体を名前の部分とする。
    private func contextTextPreviewFrames() -> AppearancePreviewFrames {
        guard let line = contextLabel.previewFrame(in: self)?.first, let text = contextLabel.attributedText else { return [:] }
        guard let range = current.context?.secondaryRange, range.location <= text.length else {
            return [.contextText: [line]]
        }
        // 名前の部分の幅は、すき間の字送りを除いて測る。字送りは名前の最後の文字の後ろに付いている。
        let primary = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: 0, length: range.location)))
        let spacing = primary.length > 0 ? (primary.attribute(.kern, at: primary.length - 1, effectiveRange: nil) as? CGFloat ?? 0) : 0
        primary.removeAttribute(.kern, range: NSRange(location: 0, length: primary.length))
        let primaryEnd = min(line.minX + ceil(primary.size().width), line.maxX)
        let secondaryStart = min(primaryEnd + spacing, line.maxX)
        let end = min(line.minX + ceil(text.size().width), line.maxX)
        return [
            .contextText: [CGRect(x: line.minX, y: line.minY, width: primaryEnd - line.minX, height: line.height)],
            .contextSecondary: [CGRect(x: secondaryStart, y: line.minY, width: max(end - secondaryStart, 0), height: line.height)],
        ]
    }

    /// 時刻の表記だけを今の時刻で書き直す。名前の行は1行で高さが決まっているため、行の高さは変わらない。
    func refreshTime(now: Date) {
        let text = current.timeText(now: now)
        if timeText != text {
            timeText = text
            timeLabel.attributedText = timeAttributedText(text, for: current)
            updateAccessibility(for: current)
        }
    }

    /// 時刻の表記に、公開範囲の記号を前置きする。記号は文字に添えるので、ベースラインに乗り、文字と同じ色で描かれる。
    private func timeAttributedText(_ text: String, for configuration: PostContentConfiguration) -> NSAttributedString {
        let font = configuration.metrics.timeFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        let result = NSMutableAttributedString()
        // 記号や「*」と時刻のすき間は、空白ではなく、その後ろに足す字送りで取る。空白の幅は文字の大きさで変わり、すき間だけを決められないため。
        if let symbolName = configuration.visibilitySymbolName,
           let image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)) {
            result.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            // 画像の添付の文字にも幅0の文字にも字送りが効かないので、後ろに空白を置き、空白の幅を差し引いた字送りで、すき間を設定の値にする。
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
            result.append(NSAttributedString(string: " ", attributes: [.kern: configuration.metrics.visibilitySymbolSpacing - spaceWidth]))
        }
        let time = NSMutableAttributedString(string: text)
        if configuration.isEdited, configuration.showsEditedMark, text.hasPrefix("*") {
            time.addAttribute(.kern, value: configuration.metrics.editedMarkSpacing, range: NSRange(location: 0, length: 1))
        }
        result.append(time)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func updateConstraints(for configuration: PostContentConfiguration) {
        NSLayoutConstraint.deactivate(variableConstraints)
        let metrics = configuration.metrics
        let margins = metrics.margins
        let nameTopGap = configuration.nameParts.map(RichTextRenderer.lineTopGap).max() ?? 0
        var constraints = [
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margins.leading),
            // 名前の行は、ラベルが1行目の上に取る空きの分だけ上に置き、字面の上端を、アイコンの上端と同じ位置にそろえる。
            avatarView.topAnchor.constraint(equalTo: nameRow.topAnchor, constant: nameTopGap),
            avatarView.widthAnchor.constraint(equalToConstant: metrics.avatarSize),
            avatarView.heightAnchor.constraint(equalToConstant: metrics.avatarSize),
            textGuide.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: metrics.avatarSpacing),
            textGuide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margins.trailing),
            nameRow.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
            nameRow.trailingAnchor.constraint(equalTo: textGuide.trailingAnchor),
            // 間隔は、名前の行の字面の下端から測る。名前の行の部分はベースラインで揃っているので、いちばん大きい文字の字面の下端を使う。
            bodyView.topAnchor.constraint(
                equalTo: nameLabels[0].lastBaselineAnchor,
                constant: (bodyView.startsWithMedia ? metrics.nameMediaSpacing : metrics.nameBodySpacing) + Self.nameBottomInset(of: configuration)
            ),
            bodyView.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: textGuide.trailingAnchor),
            // 本文が短くても、アイコンが下の余白に食い込まないようにする。
            bottomAnchor.constraint(greaterThanOrEqualTo: avatarView.bottomAnchor, constant: margins.bottom),
        ]
        if let context = configuration.context {
            // 下限だけでは高さが決まらないため、収まる最小の高さに寄せる。
            let compactContext = contextGuide.heightAnchor.constraint(equalToConstant: 0)
            compactContext.priority = .defaultLow
            constraints += [
                contextGuide.topAnchor.constraint(equalTo: topAnchor, constant: margins.top),
                contextGuide.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
                contextGuide.trailingAnchor.constraint(equalTo: textGuide.trailingAnchor),
                contextLabel.topAnchor.constraint(greaterThanOrEqualTo: contextGuide.topAnchor),
                contextLabel.bottomAnchor.constraint(lessThanOrEqualTo: contextGuide.bottomAnchor),
                contextLabel.centerYAnchor.constraint(equalTo: contextGuide.centerYAnchor),
                compactContext,
                contextLabel.trailingAnchor.constraint(lessThanOrEqualTo: textGuide.trailingAnchor),
                // 記号は本文の列から決まった幅だけ離して置き、ブーストした人のアイコンと名前は本文の列に揃える。
                // アイコンの列の右端に揃えると、細い記号では文字とのあいだが間延びして見えるため。
                contextIcon.trailingAnchor.constraint(equalTo: textGuide.leadingAnchor, constant: -metrics.contextSymbolSpacing),
                Self.symbolVerticalConstraint(contextIcon, beside: contextLabel, onBaseline: context.notificationSymbolFont != nil),
                nameRow.topAnchor.constraint(equalTo: contextGuide.bottomAnchor, constant: metrics.contextSpacing - nameTopGap),
            ]
            if context.avatar != nil {
                constraints += [
                    contextAvatarView.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor),
                    contextAvatarView.centerYAnchor.constraint(equalTo: contextGuide.centerYAnchor),
                    contextAvatarView.topAnchor.constraint(greaterThanOrEqualTo: contextGuide.topAnchor),
                    contextAvatarView.bottomAnchor.constraint(lessThanOrEqualTo: contextGuide.bottomAnchor),
                    contextAvatarView.widthAnchor.constraint(equalToConstant: metrics.boosterAvatarSize),
                    contextAvatarView.heightAnchor.constraint(equalToConstant: metrics.boosterAvatarSize),
                    contextLabel.leadingAnchor.constraint(equalTo: contextAvatarView.trailingAnchor, constant: metrics.contextAvatarTextSpacing),
                ]
            } else {
                constraints.append(contextLabel.leadingAnchor.constraint(equalTo: textGuide.leadingAnchor))
            }
        } else {
            constraints.append(nameRow.topAnchor.constraint(equalTo: topAnchor, constant: margins.top - nameTopGap))
        }
        let contentBottom = bodyView.bottomAnchor
        // アイコンの方が下まで届くときは、等しさを諦めてアイコンの下に余白を取る。
        // 文字のラベルの縦のhugging（defaultLow）より弱くし、余りの高さでラベルを伸ばさずに、本文の下に空きを置く。
        // UILabelは伸ばされた枠の上下中央に文字を描くため、伸ばすと本文が名前の行から下にずれる。
        let fitsContent = bottomAnchor.constraint(equalTo: contentBottom, constant: margins.bottom)
        fitsContent.priority = .defaultLow - 1
        // 一覧は行の高さを画素に丸め、求める高さより1画素未満だけ低くすることがある。足りない分は文字のラベルではなく下の余白から削る。
        // ラベルから削ると、UILabelは収まらない行を描かないため、本文の最後の行が消える。
        let belowContent = bottomAnchor.constraint(greaterThanOrEqualTo: contentBottom, constant: margins.bottom)
        belowContent.priority = .defaultHigh - 1
        constraints += [
            belowContent,
            fitsContent,
        ]
        variableConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    /// 名前の行のベースラインから、字面の下端まで。大きくした絵文字が字面より下へ伸びていれば、その下端まで。
    static func nameBottomInset(of configuration: PostContentConfiguration) -> CGFloat {
        configuration.nameParts.map { PostBodyView.textBottomInset(of: $0) }.reduce(largestNamePointSize(of: configuration) * PostBodyView.emBoxDescent, max)
    }

    /// 名前の行に出す文字（名前、ハンドル、時刻）のうち、いちばん大きい文字の大きさ。大きさを変えた絵文字は除く。
    static func largestNamePointSize(of configuration: PostContentConfiguration) -> CGFloat {
        var sizes = configuration.nameParts.compactMap { part in
            RichTextRenderer.textFont(in: part, range: NSRange(location: 0, length: part.length))?.pointSize
        }
        sizes.append(configuration.metrics.nameFont.pointSize)
        if configuration.showsTime {
            sizes.append(configuration.metrics.timeFont.pointSize)
        }
        return sizes.max() ?? configuration.metrics.nameFont.pointSize
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

    /// 読み上げでは、名前の上の行、名前、時刻、本文の順に1つの要素として読む。投票、サムネイル、リンクカードは別の要素のまま残す。
    private func updateAccessibility(for configuration: PostContentConfiguration) {
        var parts: [String] = []
        if let context = configuration.context {
            parts.append(context.accessibilityText)
        }
        parts += configuration.nameParts.map(\.string)
        parts.append(configuration.timeAccessibilityText(now: now()))
        parts.append(bodyView.accessibilityText)
        parts += [configuration.reactionGlow?.accessibilityText].compactMap(\.self)
        textAccessibilityElement.accessibilityLabel = parts.filter { !$0.isEmpty }.joined(separator: "、")
        textAccessibilityElement.accessibilityCustomActions = [bodyView.spoilerAccessibilityAction()].compactMap(\.self) + bodyView.linkAccessibilityActions()
            + profileAccessibilityActions(for: configuration)
        // 枠はlayoutSubviewsで決める。大きさの変わらない描き直し（絵文字の画像が届いたときなど）では並べ直しが起きないため、枠を空にせず、並べ直しを頼む。
        // 空にすると、次に並べ直すまで、VoiceOverで指でなぞってもこの行に止まらない。
        setNeedsLayout()
        // 「テキストを選択」で本文を選んでいる間は、選べるテキストビューを本文の要素の後ろに置き、読み上げでも選べるようにする。
        accessibilityElements = [textAccessibilityElement] + [bodyView.selectionTextView].compactMap(\.self) + (bodyView.poll?.accessibilityParts ?? []) + [bodyView.mediaGrid, bodyView.linkCard, bodyView.embed, bodyView.filterNote].compactMap(\.self)
    }

    private lazy var textAccessibilityElement = UIAccessibilityElement(accessibilityContainer: self)

    /// アイコンと名前の上の行のタップで開くプロフィールを、VoiceOverでは操作として開く。
    private func profileAccessibilityActions(for configuration: PostContentConfiguration) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if configuration.onOpenAccount != nil {
            actions.append(UIAccessibilityCustomAction(name: "\(configuration.authorName)のプロフィール") { [weak self] _ in
                self?.openAccount()
                return true
            })
        }
        if let context = configuration.context, context.opensAccount, let name = context.accountName, configuration.onOpenContextAccount != nil {
            actions.append(UIAccessibilityCustomAction(name: "\(name)のプロフィール") { [weak self] _ in
                self?.openContextAccount()
                return true
            })
        }
        return actions
    }

    override func layoutSubviews() {
        FrameWork.measure("PostContentView.layoutSubviews") { layoutContents() }
    }

    private func layoutContents() {
        super.layoutSubviews()
        reactionGlowView.layout(in: bounds, bottomMargin: current.metrics.margins.bottom)
        layoutReplyLines()
        // 本文の枠は中身の部品の中で決まるため、先に並べておく。
        bodyView.layoutIfNeeded()
        let bodyTextFrame = bodyView.convert(bodyView.textFrame, to: self)
        let textFrame = [contextLabel, nameRow].filter { !$0.isHidden }.map(\.frame).reduce(bodyTextFrame) { $0.union($1) }
        textAccessibilityElement.accessibilityFrameInContainerSpace = textFrame.union(avatarView.frame)
    }

    /// 線はアイコンの中心の縦に、行の上端からアイコンの上まで、アイコンの下から行の下端まで引く。アイコンとのあいだは少し空ける。
    private func layoutReplyLines() {
        let metrics = current.metrics
        let avatar = avatarView.frame
        let x = avatar.midX - metrics.replyLineWidth / 2
        let aboveBottom = max(avatar.minY - metrics.replyLineGap, 0)
        replyLineAbove.frame = CGRect(x: x, y: 0, width: metrics.replyLineWidth, height: aboveBottom)
        let belowTop = min(avatar.maxY + metrics.replyLineGap, bounds.maxY)
        replyLineBelow.frame = CGRect(x: x, y: belowTop, width: metrics.replyLineWidth, height: bounds.maxY - belowTop)
        for line in [replyLineAbove, replyLineBelow] {
            line.layer.cornerRadius = metrics.replyLineWidth / 2
        }
    }
}
