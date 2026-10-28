import SciaCore
import UIKit

/// 投稿の中身。投稿のセルと通知のセルで同じ部品を使い、どの部品をどう出すかは置く側が決める。
///
/// 上から、注意書き、本文、投票、添付ファイル、リンクカードか囲み（引用かXの投稿）の順に並べる。
/// 注意書きで折りたたんでいる間は、注意書きだけを出す。
/// 本文が空なら、本文と添付ファイルのあいだの余白も取らず、添付ファイルを上端から置く。上の行との間隔は置く側が`startsWithMedia`を見て決める。
/// 添付ファイルを重ねて出すときは、本文の右に置き、本文はその分をあけて折り返す。投票から下の部品は、本文とサムネイルのどちらよりも下に置く。
/// 本文がなくても、サムネイルの上端は本文の1行目の字面の上端と同じ位置にする。
struct PostBodyContent {
    struct Spoiler {
        /// ボックスに入れて本文を折りたたむもの。
        enum Kind {
            /// 投稿した人が付けた注意書き。開閉できる。
            case contentWarning
            /// 使う人のフィルターに一致した警告。開いたらボックスごと消え、閉じ直さない。
            case filter
        }

        var text: NSAttributedString
        var isCollapsed: Bool
        var kind: Kind = .contentWarning
        /// 注意書きのボックスの内側の余白。
        var padding: CGFloat
        /// 開いているときの、注意書きのボックスと本文のあいだ。
        var bodySpacing: CGFloat
        /// 開閉のボタンの文字。
        var buttonFont: UIFont
        /// 注意書きの文字と、開閉のボタンのあいだ。
        var buttonSpacing: CGFloat
        /// ボックスの角の丸み。
        var cornerRadius: CGFloat
    }

    /// 注意書きがなければnil。
    var spoiler: Spoiler?
    var text: NSAttributedString
    /// 本文を切る行数。0なら切らない。
    var maximumLines = 0
    /// 添付ファイルがなければnil。
    var media: MediaGridView.Content?
    /// 本文と添付ファイルのあいだの余白。本文がなければ取らない。
    var mediaSpacing: CGFloat
    /// 投票がなければnil。
    var poll: PollView.Content?
    /// 本文と投票のあいだの余白。本文がなければ取らない。
    var pollSpacing: CGFloat = 0
    /// リンクカードを出さなければnil。
    var card: LinkCardView.Content?
    /// 本文か添付ファイルと、リンクカードのあいだの余白。
    var cardSpacing: CGFloat = 0
    /// 引用かXの投稿の囲み。あれば、リンクカードの代わりに同じ位置に置く。
    var embed: EmbeddedPostView.Content?
    /// 本文か添付ファイルと、囲みのあいだ。
    var embedSpacing: CGFloat = 0
    /// 表示している投稿。リンクカードから囲みに替わったのが同じ投稿の行かを見分ける。同じXの投稿へのリンクは、別の投稿にもありうるため。
    var statusID: Status.ID?
    /// 本文のハッシュタグのメニューの「ユーザーの投稿」で開くユーザー。投稿した人。nilなら項目を出さない。
    var hashtagAccount: Account?
    /// 一番下に置く補足の1行。自分の投稿が自分のフィルターに一致していることか、通知で再掲する投稿に引用があることを示す。なければnil。
    var filterNote: NSAttributedString?
    /// 上の部品と、フィルターの注記のあいだ。
    var filterNoteSpacing: CGFloat = 0
}

/// 囲みの押下と、囲みの中の部品の押下で呼ぶ処理。引用とXの投稿で開く先が違うため、置く側が決める。
struct EmbedActions {
    /// 囲みが押されたときに、囲みを渡して呼ぶ。
    var open: ((EmbeddedPostView) -> Void)?
    /// 囲みのタップと長押し。渡すと、タップは`open`の代わりにこれで行い、長押しでは囲みの対象のメニューか、選んだ操作を行う。
    /// 決まりはdocs/object-actions.mdにある。
    var target: (any ObjectActionTarget)?
    /// 囲みの作者のアイコンのタップと長押し。
    var accountTarget: (any ObjectActionTarget)?
    /// 囲みのサムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var selectMedia: ((Int, MediaGridView) -> Void)?
    /// 囲みの添付ファイルの、閲覧注意のぼかしが押されたときに呼ぶ。
    var revealMedia: (() -> Void)?
    /// 囲みの本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var openLink: ((RichText.LinkDestination) -> Void)?
    /// 囲みの作者のアイコンがタップされたときに呼ぶ。
    var openAccount: (() -> Void)?
    /// 囲みの注意書きが押されたときに呼ぶ。
    var toggleSpoiler: (() -> Void)?
    /// 囲みの押せる補足の行がタップされたときに、何番目の行かを渡して呼ぶ。
    var selectNote: ((Int) -> Void)?
}

final class PostBodyView: UIView {
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    /// 添付ファイルか、リンクカードの画像の、閲覧注意のぼかしが押されたときに呼ぶ。ぼかしを外すのは置く側で、適用し直すまで見た目は変わらない。
    var onRevealMedia: (() -> Void)?
    /// 注意書きが押されたときに呼ぶ。開閉した状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onToggleSpoiler: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// リンクカードの画像がタップされたときに、ビューアを開閉する起点として、サムネイルを渡して呼ぶ。
    var onOpenLinkCardImage: ((LinkCardThumbnailView) -> Void)?
    /// 囲みの押下と、囲みの中の部品の押下を受ける。
    var embedActions = EmbedActions() {
        didSet {
            embedInteraction?.target = embedActions.target
            embedView?.accountTarget = embedActions.accountTarget
        }
    }
    /// リンクカードのタップと長押し。渡すと、タップは`onOpenLink`の代わりにこれで行い、長押しではリンクのメニューか、選んだ操作を行う。
    var cardTarget: (any ObjectActionTarget)? {
        didSet { cardInteraction?.target = cardTarget }
    }
    private var cardInteraction: ObjectInteraction?
    private var embedInteraction: ObjectInteraction?
    /// 投票の選択肢やボタンが押されたときに呼ぶ。選んだ状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onPollAction: ((PollView.Action) -> Void)?

    private let mediaImages: MediaImageStore
    private let avatarImages: AvatarImageStore
    private let textLabel = LinkLabel()
    /// 本文の最初と最後のベースラインの位置。本文の上下のすき間は字面から測るので、「投稿の見た目」のプレビューで字面の枠を求めるのに使う。
    private let textFirstBaselineGuide = UILayoutGuide()
    private let textLastBaselineGuide = UILayoutGuide()
    /// フィルターの注記の最初のベースラインの位置。注記の上のすき間も字面から測るので、プレビューで字面の上端を求めるのに使う。
    private let filterNoteBaselineGuide = UILayoutGuide()
    // 本文のほかの部品は、その中身が初めて来たときに作り、そのあとは隠して持っておく。
    // どれも持たない投稿が多いのに、行を作るたびに全部を作ると、まとめて行を作る画面の最初の表示でメインスレッドが止まるため。
    private var spoilerView: SpoilerView?
    private var pollView: PollView?
    private var mediaView: MediaGridView?
    private var cardView: LinkCardView?
    private var embedView: EmbeddedPostView?
    /// 囲みに替わったリンクカードの像。囲みを濃くする間、カードのあった位置に重ねて薄くする。
    private(set) var leavingCardSnapshot: UIView?
    private var filterNoteLabel: UILabel?
    /// 「テキストを選択」で、本文のラベルの代わりに同じ位置に出している選べるテキストビュー。選んでいなければnil。
    private(set) var selectionTextView: SelectableTextView?
    private(set) var content: PostBodyContent?
    /// 添付ファイルの有無と並べ方で変わる制約。適用のたびに作り直す。
    private var variableConstraints: [NSLayoutConstraint] = []
    /// 本文の右端。添付ファイルを本文の右に出すときは、その分を左へ寄せる。
    private var textTrailing: NSLayoutConstraint?
    /// 添付ファイルを本文の右に出すとき、本文の字面とサムネイルの下端のうち、下にあるほう。投票から下の部品をここから並べる。
    private let besideGuide = UILayoutGuide()
    /// 添付ファイルを本文の右に出し、その下に何も置かないとき、本文のラベルとサムネイルの下端のうち、下にあるほう。自分の下端にする。
    /// 本文の下に並べるときと同じく、本文で終わる行の下端は字面ではなくラベルの下端にする。
    private let besideEndGuide = UILayoutGuide()

    /// 表示中のサムネイル。ビューアの拡大と縮小の起点を探すときに使う。
    var mediaGrid: MediaGridView? {
        Self.shown(mediaView)
    }

    /// 表示中のリンクカード。読み上げの要素に加える。
    var linkCard: LinkCardView? {
        Self.shown(cardView)
    }

    /// 表示中の囲み。読み上げの要素に加え、ビューアの拡大と縮小の起点を探すときにも使う。
    var embed: EmbeddedPostView? {
        Self.shown(embedView)
    }

    /// 表示中の投票。読み上げの要素に加える。
    var poll: PollView? {
        Self.shown(pollView)
    }

    /// 表示中のフィルターの注記。添付ファイルやリンクカードより下にあるため、読み上げでは本文と分け、それらの後の要素にする。
    var filterNote: UILabel? {
        Self.shown(filterNoteLabel)
    }

    /// 注意書きも本文もなく、添付ファイルが上端から始まる。
    /// 本文の右に出すときは、本文がなくても本文の位置から置くので、当てはまらない。
    var startsWithMedia: Bool {
        Self.shown(spoilerView) == nil && textLabel.isHidden && mediaGrid != nil && mediaGrid?.content?.isStacked != true
    }

    /// 「投稿の見た目」のプレビューで、部品の場所を示すための枠。`space`の座標で返す。
    func previewFrames(in space: UIView) -> AppearancePreviewFrames {
        var frames: AppearancePreviewFrames = [
            .spoiler: Self.shown(spoilerView)?.previewFrame(in: space),
            .spoilerButton: Self.shown(spoilerView)?.buttonPreviewFrame(in: space),
            .spoilerText: Self.shown(spoilerView)?.textPreviewFrame(in: space),
            .bodyText: textLabel.previewFrame(in: space),
            .bodyGlyphs: textGlyphsFrame(in: space),
            .card: linkCard?.previewFrame(in: space),
            .poll: poll?.previewFrame(in: space),
            .pollOptions: poll?.optionsPreviewFrame(in: space),
            .filterNote: filterNoteGlyphsFrame(in: space),
            .pollFooter: poll?.footerPreviewFrame(in: space),
        ].compactMapValues(\.self)
        if let card = linkCard {
            frames.merge(card.textPreviewFrames(in: space)) { $1 }
        }
        if let embed {
            frames.merge(embed.previewFrames(in: space)) { $1 }
        }
        frames.merge(textLinePreviewFrames(in: space)) { $1 }
        if let spoiler = Self.shown(spoilerView)?.previewFrame(in: space)?.first, let content = content?.spoiler {
            frames[.spoilerPaddingBands] = AppearanceHighlight.paddingBands(of: spoiler, padding: content.padding)
            frames[.spoilerCorners] = AppearanceHighlight.cornerSquares(of: spoiler, radius: content.cornerRadius)
        }
        if let summary = poll?.summaryPreviewFrame(in: space) {
            frames[.pollSummary] = summary
        }
        frames.merge(mediaPreviewFrames(in: space)) { $1 }
        if let options = poll?.optionPreviewFrames(in: space), !options.isEmpty {
            if options.count > 1 {
                frames[.pollOptionGaps] = AppearanceHighlight.gaps(between: options.map(\.option))
            }
            let radius = content?.poll?.optionCornerRadius ?? 0
            frames[.pollOptionCorners] = options.flatMap { AppearanceHighlight.cornerSquares(of: $0.option, radius: radius) }
            let side = content?.poll?.optionHorizontalPadding ?? 0
            frames[.pollOptionSidePadding] = options.flatMap { option, _ in
                [
                    CGRect(x: option.minX, y: option.minY, width: side, height: option.height),
                    CGRect(x: option.maxX - side, y: option.minY, width: side, height: option.height),
                ]
            }
            frames[.pollOptionPadding] = options.flatMap { option, title in
                [
                    CGRect(x: option.minX, y: option.minY, width: option.width, height: max(title.minY - option.minY, AppearanceHighlight.minimumGapThickness)),
                    CGRect(x: option.minX, y: title.maxY, width: option.width, height: max(option.maxY - title.maxY, AppearanceHighlight.minimumGapThickness)),
                ]
            }
        }
        return frames
    }

    /// 添付ファイルの枠。本文の右に重ねて出すときは、本文の下に並べたときと示す項目が違うので、別の部品として返す。
    private func mediaPreviewFrames(in space: UIView) -> AppearancePreviewFrames {
        guard let grid = mediaGrid, let frame = grid.previewFrame(in: space) else { return [:] }
        var frames: AppearancePreviewFrames = [:]
        let badges = grid.badgePreviewFrames(in: space)
        if !badges.isEmpty {
            frames[.mediaBadgeSlot] = badges
        }
        // 重ねたサムネイルには、すき間も1つのときの比率も効かないので示さない。
        if grid.content?.isStacked == true {
            frames[.besideMedia] = frame
            return frames
        }
        frames[.media] = frame
        let tiles = grid.tilePreviewFrames(in: space)
        if tiles.count > 1 {
            frames[.mediaTileGaps] = AppearanceHighlight.gaps(between: tiles)
        } else if !tiles.isEmpty {
            frames[.singleMedia] = tiles
            if let ratio = content?.media?.attachments.first?.aspectRatio {
                frames[ratio < 1 ? .singleTallMedia : .singleWideMedia] = tiles
            }
        }
        return frames
    }

    /// 本文の行間、段落のあいだ、字下げの枠。行の位置は、UILabelと同じ並べ方で求める。
    private func textLinePreviewFrames(in space: UIView) -> AppearancePreviewFrames {
        guard !textLabel.isHidden, let label = textLabel.previewFrame(in: space)?.first else { return [:] }
        let lines = textLabel.previewLines().map { line in
            (frame: textLabel.convert(line.frame, to: space), startsParagraph: line.startsParagraph, indent: line.indent)
        }
        var lineGaps: [CGRect] = []
        var paragraphGaps: [CGRect] = []
        for (above, below) in zip(lines, lines.dropFirst()) {
            let gap = CGRect(x: label.minX, y: above.frame.maxY, width: label.width, height: max(below.frame.minY - above.frame.maxY, 0))
            if below.startsParagraph {
                paragraphGaps.append(gap)
            } else {
                lineGaps.append(gap)
            }
        }
        let indents = lines.filter { $0.indent > 0 }.map { CGRect(x: label.minX, y: $0.frame.minY, width: $0.indent, height: $0.frame.height) }
        var frames: AppearancePreviewFrames = [:]
        frames[.bodyLineGaps] = lineGaps.isEmpty ? nil : lineGaps
        frames[.bodyParagraphGaps] = paragraphGaps.isEmpty ? nil : paragraphGaps
        frames[.quoteIndent] = indents.isEmpty ? nil : indents
        let emojis = textLabel.previewCustomEmojiFrames().map { textLabel.convert($0, to: space) }
        frames[.customEmojis] = emojis.isEmpty ? nil : emojis
        return frames
    }

    /// 本文の字面の枠。上端は最初のベースラインから、下端は最後のベースラインから、em枠で測る。並びも同じ測り方で、すき間を取っている。
    private func textGlyphsFrame(in space: UIView) -> [CGRect]? {
        guard let label = textLabel.previewFrame(in: space)?.first, let text = textLabel.attributedText else { return nil }
        let top = convert(CGPoint(x: 0, y: textFirstBaselineGuide.layoutFrame.minY - Self.textTopInset(of: text)), to: space).y
        let bottom = convert(CGPoint(x: 0, y: textLastBaselineGuide.layoutFrame.minY + Self.textBottomInset(of: text)), to: space).y
        return [CGRect(x: label.minX, y: top, width: label.width, height: max(bottom - top, 0))]
    }

    /// フィルターの注記の枠。上端は、最初のベースラインからem枠で測った字面の上端にする。
    private func filterNoteGlyphsFrame(in space: UIView) -> [CGRect]? {
        guard let note = filterNote, let frame = note.previewFrame(in: space)?.first, let text = note.attributedText else { return nil }
        let top = convert(CGPoint(x: 0, y: filterNoteBaselineGuide.layoutFrame.minY - Self.textTopInset(of: text)), to: space).y
        return [CGRect(x: frame.minX, y: top, width: frame.width, height: max(frame.maxY - top, 0))]
    }

    /// 注意書きと本文の枠。読み上げの要素の範囲を決めるときに使う。
    var textFrame: CGRect {
        [Self.shown(spoilerView), Self.shown(textLabel)].compactMap(\.self).map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    /// 注意書きと本文のアニメーションするカスタム絵文字を動かすときに、アニメーション版を読み込むストア。nilなら動かさない。
    var emojiImages: EmojiImageStore? {
        get { textLabel.emojiImages }
        set {
            textLabel.emojiImages = newValue
            spoilerView?.emojiImages = newValue
            pollView?.emojiImages = newValue
            embedView?.emojiImages = newValue
        }
    }

    init(mediaImages: MediaImageStore, avatarImages: AvatarImageStore) {
        self.mediaImages = mediaImages
        self.avatarImages = avatarImages
        super.init(frame: .zero)
        textLabel.numberOfLines = 0
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)
        let textTrailing = textLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.textTrailing = textTrailing
        NSLayoutConstraint.activate([textLabel.leadingAnchor.constraint(equalTo: leadingAnchor), textTrailing])
        for guide in [textFirstBaselineGuide, textLastBaselineGuide, besideGuide, besideEndGuide] {
            addLayoutGuide(guide)
        }
        NSLayoutConstraint.activate([
            textFirstBaselineGuide.topAnchor.constraint(equalTo: textLabel.firstBaselineAnchor),
            textFirstBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
            textLastBaselineGuide.topAnchor.constraint(equalTo: textLabel.lastBaselineAnchor),
            textLastBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
        ])
        textLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
    }

    private static func shown<View: UIView>(_ view: View?) -> View? {
        view?.isHidden == false ? view : nil
    }

    /// 左右の端を自分に揃えて載せる。縦の位置は、適用のたびに決める。
    private func install(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func loadedSpoilerView() -> SpoilerView {
        if let spoilerView { return spoilerView }
        let view = SpoilerView()
        view.emojiImages = textLabel.emojiImages
        install(view)
        view.topAnchor.constraint(equalTo: topAnchor).isActive = true
        view.addAction(UIAction { [weak self] _ in self?.onToggleSpoiler?() }, for: .touchUpInside)
        spoilerView = view
        return view
    }

    private func loadedPollView() -> PollView {
        if let pollView { return pollView }
        let view = PollView()
        view.emojiImages = textLabel.emojiImages
        install(view)
        view.onAction = { [weak self] action in self?.onPollAction?(action) }
        pollView = view
        return view
    }

    private func loadedMediaView() -> MediaGridView {
        if let mediaView { return mediaView }
        let view = MediaGridView(store: mediaImages)
        // 左右の位置は、並べ方で変わるため適用のたびに決める。
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        view.onSelect = { [weak self] index in
            guard let self, let mediaView = self.mediaView else { return }
            self.onSelectMedia?(index, mediaView)
        }
        view.onReveal = { [weak self] in self?.onRevealMedia?() }
        mediaView = view
        return view
    }

    private func loadedCardView() -> LinkCardView {
        if let cardView { return cardView }
        let view = LinkCardView(store: mediaImages)
        install(view)
        view.onOpenImage = { [weak self] thumbnail in self?.onOpenLinkCardImage?(thumbnail) }
        view.onRevealImage = { [weak self] in self?.onRevealMedia?() }
        let interaction = ObjectInteraction(on: view, tapsSelf: false)
        cardInteraction = interaction
        view.addAction(UIAction { [weak self, weak interaction] _ in
            guard let self, let url = self.cardView?.content?.card.url else { return }
            if interaction?.target != nil {
                interaction?.handleTap()
            } else {
                self.onOpenLink?(.url(url))
            }
        }, for: .primaryActionTriggered)
        cardInteraction?.target = cardTarget
        cardView = view
        return view
    }

    private func loadedEmbedView() -> EmbeddedPostView {
        if let embedView { return embedView }
        let view = EmbeddedPostView(store: mediaImages, avatarImages: avatarImages)
        view.emojiImages = textLabel.emojiImages
        install(view)
        view.onSelectMedia = { [weak self] index, grid in self?.embedActions.selectMedia?(index, grid) }
        view.onRevealMedia = { [weak self] in self?.embedActions.revealMedia?() }
        view.onOpenLink = { [weak self] destination in self?.embedActions.openLink?(destination) }
        view.onOpenAccount = { [weak self] in self?.embedActions.openAccount?() }
        view.onToggleSpoiler = { [weak self] in self?.embedActions.toggleSpoiler?() }
        view.onSelectNote = { [weak self] index in self?.embedActions.selectNote?(index) }
        let interaction = ObjectInteraction(on: view, tapsSelf: false)
        embedInteraction = interaction
        view.addAction(UIAction { [weak self, weak view, weak interaction] _ in
            guard let self, let view else { return }
            if interaction?.target != nil {
                interaction?.handleTap()
            } else {
                self.embedActions.open?(view)
            }
        }, for: .primaryActionTriggered)
        embedInteraction?.target = embedActions.target
        view.accountTarget = embedActions.accountTarget
        embedView = view
        return view
    }

    private func loadedFilterNoteLabel() -> UILabel {
        if let filterNoteLabel { return filterNoteLabel }
        let label = UILabel()
        label.numberOfLines = 0
        install(label)
        addLayoutGuide(filterNoteBaselineGuide)
        NSLayoutConstraint.activate([
            filterNoteBaselineGuide.topAnchor.constraint(equalTo: label.firstBaselineAnchor),
            filterNoteBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
        ])
        filterNoteLabel = label
        return label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 「テキストを選択」で本文を選べる状態にできるか。本文を表示していて、行数で切っていないときだけできる。
    /// 切った本文は、切った部分を選べず、高さを変えずに全文を出せないため。
    var canSelectText: Bool {
        guard let content, !textLabel.isHidden, content.maximumLines == 0 else { return false }
        return !content.text.string.allSatisfy(\.isWhitespace)
    }

    /// 本文を選べる状態にしたときと、やめたときに呼ぶ。置く側は、読み上げの要素を差し替える。
    var onTextSelectionChange: (() -> Void)?

    /// 本文を選べる状態にしている。
    var isSelectingText: Bool {
        selectionTextView != nil
    }

    /// 本文の上に重ねた選べるテキストビューの、自分の座標での枠。選んでいなければnil。
    var textSelectionFrame: CGRect? {
        selectionTextView?.frame
    }

    /// 本文のラベルを、同じ文字列を同じ位置に並べる選べるテキストビューに差し替え、全体を選ぶ。決まりはdocs/menus.mdの「本文の文字を選ぶ」にある。
    /// ラベルは並べ方の基準に使っているので外さず、透明にして残す。透明なラベルは押下も受けないため、リンクは開かない。
    func beginTextSelection() {
        guard canSelectText, selectionTextView == nil, let text = textLabel.textForTextKit else { return }
        let view = SelectableTextView(text: text)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: textLabel.topAnchor),
            view.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: textLabel.trailingAnchor),
        ])
        view.touchableHeight = { [weak textLabel] in textLabel?.bounds.height }
        textLabel.alpha = 0
        selectionTextView = view
        layoutIfNeeded()
        view.beginSelectingAll()
        // 選び始めるときにテキストビューの選択が一度空になることがあるため、選んでから終わりを受け取る。
        view.onEnd = { [weak self] in self?.endTextSelection() }
        onTextSelectionChange?()
    }

    /// 本文を選べる状態をやめ、ラベルに戻す。
    func endTextSelection() {
        guard let view = selectionTextView else { return }
        selectionTextView = nil
        view.onEnd = nil
        view.removeFromSuperview()
        textLabel.alpha = 1
        onTextSelectionChange?()
    }

    func apply(_ content: PostBodyContent) {
        let previous = self.content
        defer {
            // 同じ投稿の描き直し（画像が届いた、数が変わったなど）では選んだままにし、別の投稿に替わったときと、本文が変わったか選べなくなったときにやめる。
            // 選んだままにするときも、絵文字の画像や絵文字そのものは替わりうるので、ラベルと同じ中身にそろえる。
            if isSelectingText {
                if previous?.statusID != content.statusID || previous?.text.string != content.text.string || !canSelectText {
                    endTextSelection()
                } else if let text = textLabel.textForTextKit {
                    selectionTextView?.replaceText(text)
                }
            }
        }
        self.content = content
        textLabel.attributedText = Self.truncatingTail(content.text, when: content.maximumLines > 0)
        textLabel.hashtagAccount = content.hashtagAccount
        textLabel.numberOfLines = content.maximumLines
        NSLayoutConstraint.deactivate(variableConstraints)
        variableConstraints = []
        let shownSpoiler = applySpoiler(content.spoiler)
        let isCollapsed = content.spoiler?.isCollapsed ?? false
        let poll = isCollapsed ? nil : content.poll
        let media = isCollapsed ? nil : content.media.flatMap { $0.aspectRatio == nil ? nil : $0 }
        let besideSide: CGFloat? = if case .stack(let side)? = media?.arrangement { side } else { nil }
        textTrailing?.constant = besideSide.map { -($0 + content.mediaSpacing) } ?? 0
        let embed = isCollapsed ? nil : content.embed
        let card = isCollapsed || embed != nil ? nil : content.card
        textLabel.isHidden = isCollapsed || (content.text.length == 0 && (poll != nil || media != nil || card != nil || embed != nil || content.spoiler != nil))
        // 本文と添付ファイルは、注意書きがあればその下から並べる。
        let contentTop = shownSpoiler?.bottomAnchor ?? topAnchor
        let contentTopSpacing = shownSpoiler == nil ? 0 : content.spoiler?.bodySpacing ?? 0
        let text = textLabel.isHidden ? nil : (label: textLabel, bottomInset: Self.textBottomInset(of: content.text))
        if !textLabel.isHidden {
            variableConstraints.append(textLabel.firstBaselineAnchor.constraint(equalTo: contentTop, constant: contentTopSpacing + Self.textTopInset(of: content.text)))
        }
        let besideBottom = media.flatMap { media in
            besideSide.map { applyBesideMedia(media, side: $0, top: contentTop, topSpacing: contentTopSpacing, text: text) }
        }
        let placement = Placement(contentTop: contentTop, contentTopSpacing: contentTopSpacing, text: text, besideBottom: besideBottom?.parts)
        let shownPoll = applyPoll(poll, spacing: content.pollSpacing, placement: placement)
        let shownMedia = besideSide == nil ? applyMedia(media, below: shownPoll, spacing: content.mediaSpacing, placement: placement) : nil
        let replacesCard = previous?.embed == nil && previous?.card != nil && content.statusID != nil && previous?.statusID == content.statusID
        let fadesInEmbed = embed.map { replacesCard && window != nil && $0.transitionDuration > 0 && !UIAccessibility.isReduceMotionEnabled } ?? false
        // 別の投稿に替わったときと、注意書きを折りたたんで囲みを隠したときは、カードの像を残さない。
        // 同じ投稿の描き直し（画像が届いたなど）では、薄くし続ける。
        let isSameStatus = previous?.statusID == content.statusID
        if !isSameStatus || embed == nil {
            removeLeavingCardSnapshot()
        }
        // カードは隠す前に像を取っておき、囲みと入れ替えて薄くする。
        let leavingCard = fadesInEmbed ? leaveCard() : nil
        let shownCard = applyCard(card, below: shownMedia ?? shownPoll, spacing: content.cardSpacing, placement: placement)
        // 同じ投稿の囲みを描き直すだけなら、浮かび上がらせている途中の濃さを変えない。
        let keepsEmbedFade = isSameStatus && previous?.embed != nil && !(previous?.spoiler?.isCollapsed ?? false)
        let shownEmbed = applyEmbed(embed, fadesIn: fadesInEmbed, keepsFade: keepsEmbedFade, leavingCard: leavingCard, below: shownMedia ?? shownPoll, spacing: content.embedSpacing, placement: placement)
        // 添付ファイルもリンクカードもないのに本文を隠すのは、注意書きがあるときだけ。
        let last: Bottom = if let shownEmbed {
            .view(shownEmbed)
        } else if let shownCard {
            .view(shownCard)
        } else if let shownMedia {
            .view(shownMedia)
        } else if let shownPoll {
            .view(shownPoll)
        } else if let besideBottom {
            .beside(parts: besideBottom.parts, end: besideBottom.end)
        } else if textLabel.isHidden, let shownSpoiler {
            .view(shownSpoiler)
        } else {
            .view(textLabel)
        }
        applyFilterNote(content.filterNote, below: last, spacing: content.filterNoteSpacing, textBottomInset: Self.textBottomInset(of: content.text))
        NSLayoutConstraint.activate(variableConstraints)
    }

    /// 本文の下の部品を縦に並べるときの、上端の決め方。
    @MainActor
    private struct Placement {
        /// 本文と添付ファイルを並べ始める位置。注意書きがあればその下。
        let contentTop: NSLayoutYAxisAnchor
        let contentTopSpacing: CGFloat
        /// 出している本文と、その最後の文字の、ベースラインから字面の下端まで。本文を出していなければnil。
        let text: (label: UILabel, bottomInset: CGFloat)?
        /// 添付ファイルを本文の右に出すとき、本文の字面とサムネイルの下端のうち、下にあるほう。出さなければnil。
        let besideBottom: NSLayoutYAxisAnchor?

        /// 上の部品の下端から、次の部品を置く位置。本文の下なら、字面の下端から測る。本文の右に添付ファイルがあれば、その下端とも比べる。
        func top(of view: UIView, below shownAbove: UIView?, spacing: CGFloat) -> NSLayoutConstraint {
            if let shownAbove {
                view.topAnchor.constraint(equalTo: shownAbove.bottomAnchor, constant: spacing)
            } else if let besideBottom {
                view.topAnchor.constraint(equalTo: besideBottom, constant: spacing)
            } else if let text {
                view.topAnchor.constraint(equalTo: text.label.lastBaselineAnchor, constant: spacing + text.bottomInset)
            } else {
                view.topAnchor.constraint(equalTo: contentTop, constant: contentTopSpacing)
            }
        }
    }

    /// 出した注意書きのボックスを返す。
    private func applySpoiler(_ spoiler: PostBodyContent.Spoiler?) -> SpoilerView? {
        guard let spoiler else {
            spoilerView?.isHidden = true
            return nil
        }
        let spoilerView = loadedSpoilerView()
        spoilerView.isHidden = false
        spoilerView.apply(SpoilerView.Content(text: spoiler.text, isCollapsed: spoiler.isCollapsed, kind: spoiler.kind, padding: spoiler.padding, buttonFont: spoiler.buttonFont, buttonSpacing: spoiler.buttonSpacing, cornerRadius: spoiler.cornerRadius))
        return spoilerView
    }

    /// 出した投票を返す。
    private func applyPoll(_ poll: PollView.Content?, spacing: CGFloat, placement: Placement) -> PollView? {
        guard let poll else {
            pollView?.isHidden = true
            return nil
        }
        let pollView = loadedPollView()
        pollView.isHidden = false
        pollView.apply(poll)
        variableConstraints.append(placement.top(of: pollView, below: nil, spacing: spacing))
        return pollView
    }

    /// 出した添付ファイルの欄を返す。
    private func applyMedia(_ media: MediaGridView.Content?, below shownAbove: UIView?, spacing: CGFloat, placement: Placement) -> MediaGridView? {
        guard let media, let aspectRatio = media.aspectRatio else {
            mediaView?.isHidden = true
            return nil
        }
        let mediaView = loadedMediaView()
        mediaView.isHidden = false
        mediaView.apply(media)
        let height = switch media.arrangement {
        case .grid: mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: 1 / aspectRatio)
        case .strip(let side), .stack(let side): mediaView.heightAnchor.constraint(equalToConstant: side)
        }
        variableConstraints += [
            placement.top(of: mediaView, below: shownAbove, spacing: spacing),
            mediaView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mediaView.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
        ]
        return mediaView
    }

    /// 添付ファイルを本文の右に、一辺`side`の正方形で出す。上端は本文の1行目の字面の上端にそろえる。
    /// - Returns: 本文の字面とサムネイルの下端のうち下にあるほう（下の部品を並べ始める位置）と、本文のラベルとサムネイルの下端のうち下にあるほう（ほかに何もないときの自分の下端）。
    private func applyBesideMedia(_ media: MediaGridView.Content, side: CGFloat, top: NSLayoutYAxisAnchor, topSpacing: CGFloat, text: (label: UILabel, bottomInset: CGFloat)?) -> (parts: NSLayoutYAxisAnchor, end: NSLayoutYAxisAnchor) {
        let mediaView = loadedMediaView()
        mediaView.isHidden = false
        mediaView.apply(media)
        variableConstraints += [
            mediaView.topAnchor.constraint(equalTo: top, constant: topSpacing),
            mediaView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mediaView.widthAnchor.constraint(equalToConstant: side),
            mediaView.heightAnchor.constraint(equalToConstant: side),
        ]
        let mediaBottom = (anchor: mediaView.bottomAnchor, inset: CGFloat(0))
        let textGlyphsBottom = text.map { (anchor: $0.label.lastBaselineAnchor, inset: $0.bottomInset) }
        let textLabelBottom = text.map { (anchor: $0.label.bottomAnchor, inset: CGFloat(0)) }
        variableConstraints += lowestBottom(besideGuide, top: top, of: [mediaBottom, textGlyphsBottom].compactMap(\.self))
        variableConstraints += lowestBottom(besideEndGuide, top: top, of: [mediaBottom, textLabelBottom].compactMap(\.self))
        return (besideGuide.bottomAnchor, besideEndGuide.bottomAnchor)
    }

    /// `guide`の下端を、`bottoms`のうち一番下にあるものに合わせる。上端を`top`に置いて高さをできるだけ縮めるので、どれよりも下で一番上の位置に決まる。
    private func lowestBottom(_ guide: UILayoutGuide, top: NSLayoutYAxisAnchor, of bottoms: [(anchor: NSLayoutYAxisAnchor, inset: CGFloat)]) -> [NSLayoutConstraint] {
        // 本文のラベルの縮みにくさ（`.defaultHigh`）より低くする。同じだと、ラベルを縮めてサムネイルの高さで本文を切ってしまう。
        let collapse = guide.heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        return [guide.topAnchor.constraint(equalTo: top), collapse] + bottoms.map {
            guide.bottomAnchor.constraint(greaterThanOrEqualTo: $0.anchor, constant: $0.inset)
        }
    }

    /// 出したリンクカードを返す。
    private func applyCard(_ card: LinkCardView.Content?, below shownAbove: UIView?, spacing: CGFloat, placement: Placement) -> LinkCardView? {
        guard let card else {
            cardView?.isHidden = true
            return nil
        }
        let cardView = loadedCardView()
        cardView.isHidden = false
        cardView.apply(card)
        variableConstraints.append(placement.top(of: cardView, below: shownAbove, spacing: spacing))
        return cardView
    }

    /// 出した囲みを返す。
    /// - Parameter fadesIn: 同じ投稿のリンクカードから替わった（Xの投稿を読み終えた）。このときだけ、カードの像を薄くしながら囲みを浮かび上がらせる。
    ///   行が伸びる動きは一覧が付ける。使い回された行で別の投稿に替わったときは、動かさずに出す。
    /// - Parameter keepsFade: 同じ投稿の囲みを描き直すだけ。浮かび上がらせている途中なら、その濃さのまま動かし続ける。
    private func applyEmbed(_ embed: EmbeddedPostView.Content?, fadesIn: Bool, keepsFade: Bool, leavingCard: UIView?, below shownAbove: UIView?, spacing: CGFloat, placement: Placement) -> EmbeddedPostView? {
        guard let embed else {
            embedView?.isHidden = true
            return nil
        }
        let embedView = loadedEmbedView()
        embedView.isHidden = false
        embedView.apply(embed)
        // 一覧は行の高さを動かす動きの中で描き直すため、その動きに乗せず、すぐ消す。乗せると、濃い状態から薄くなる途中で
        // 濃くし始め、1コマで囲みが出て見える。濃くしている途中の行が別の投稿に使い回されたときも、その動きを止める。
        if fadesIn {
            embedView.stopFading(at: 0)
        } else if !keepsFade {
            embedView.stopFading(at: 1)
        }
        if fadesIn {
            let statusID = content?.statusID
            // 一覧は動きを止めて描き直すことがあり、その中ではUIView.animateが動かないため、描き直しを終えてから動かす。
            DispatchQueue.main.async { [weak self] in
                guard let self, let embedView = self.embedView else { return }
                // 待つ間に同じ投稿の囲みが描き直された（絵文字が届いたなど）だけなら、そのまま浮かび上がらせる。
                guard self.content?.statusID == statusID, self.content?.embed != nil, self.embed != nil else {
                    embedView.stopFading(at: 1)
                    self.removeLeavingCardSnapshot()
                    return
                }
                self.animateEmbedArrival(embedView, leavingCard: leavingCard, duration: embed.transitionDuration)
            }
        }
        variableConstraints.append(placement.top(of: embedView, below: shownAbove, spacing: spacing))
        return embedView
    }

    /// 出しているリンクカードの像を、カードの位置に重ねて返す。カードを出していなければnil。
    private func leaveCard() -> UIView? {
        removeLeavingCardSnapshot()
        guard let cardView = Self.shown(cardView), let snapshot = cardView.snapshotView(afterScreenUpdates: false) else { return nil }
        // 一覧は行の高さを動かす動きの中で描き直すため、像の置き場所がその動きに乗って左上から動かないよう、動きの外で置く。
        UIView.performWithoutAnimation {
            snapshot.frame = cardView.frame
            snapshot.isUserInteractionEnabled = false
            addSubview(snapshot)
        }
        leavingCardSnapshot = snapshot
        return snapshot
    }

    /// カードの像を先に薄くし、囲みを少し遅れて濃くする。同時に入れ替えると、出だしで両方が濃いまま重なって読めないため（リンクカードの文字の入れ替えと同じ）。
    private func animateEmbedArrival(_ embedView: EmbeddedPostView, leavingCard: UIView?, duration: TimeInterval) {
        if let leavingCard {
            UIView.animateSmoothly(duration: duration * 0.4) {
                leavingCard.alpha = 0
            } completion: { [weak self] in
                guard let self, self.leavingCardSnapshot === leavingCard else { return }
                self.removeLeavingCardSnapshot()
            }
        }
        UIView.animateSmoothly(duration: duration * 0.6, delay: duration * 0.2) {
            embedView.alpha = 1
        }
    }

    private func removeLeavingCardSnapshot() {
        leavingCardSnapshot?.removeFromSuperview()
        leavingCardSnapshot = nil
    }

    /// 一番下の部品。
    private enum Bottom {
        case view(UIView)
        /// 本文の右に添付ファイルを出し、その下に何もない。`parts`は本文の字面とサムネイルの、`end`は本文のラベルとサムネイルの、下にあるほうの下端。
        case beside(parts: NSLayoutYAxisAnchor, end: NSLayoutYAxisAnchor)
    }

    /// フィルターの注記を一番下の部品の下に置き、自分の下端を決める。
    /// - Parameter textBottomInset: 一番下が本文のときの、最後の文字のベースラインから字面の下端まで。
    private func applyFilterNote(_ note: NSAttributedString?, below bottom: Bottom, spacing: CGFloat, textBottomInset: CGFloat) {
        guard let note else {
            filterNoteLabel?.isHidden = true
            let end = switch bottom {
            case .view(let last): last.bottomAnchor
            case .beside(_, let end): end
            }
            variableConstraints.append(bottomAnchor.constraint(equalTo: end))
            return
        }
        let filterNoteLabel = loadedFilterNoteLabel()
        filterNoteLabel.isHidden = false
        filterNoteLabel.attributedText = note
        // 先頭の記号は画像の文字なので、読み上げでは除く。
        filterNoteLabel.accessibilityLabel = note.string.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFC}").union(.whitespaces))
        // 本文の下なら、ほかの部品と同じく字面の下端から測る。
        let lastBottom = switch bottom {
        case .view(let last) where last === textLabel: (anchor: textLabel.lastBaselineAnchor, inset: textBottomInset)
        case .view(let last): (anchor: last.bottomAnchor, inset: CGFloat(0))
        case .beside(let parts, _): (anchor: parts, inset: CGFloat(0))
        }
        variableConstraints += [
            filterNoteLabel.firstBaselineAnchor.constraint(equalTo: lastBottom.anchor, constant: lastBottom.inset + spacing + Self.textTopInset(of: note)),
            bottomAnchor.constraint(equalTo: filterNoteLabel.lastBaselineAnchor, constant: Self.textBottomInset(of: note)),
        ]
    }

    /// 和文の字面の枠（em枠）の、ベースラインから上端と下端までの距離。日本語の字面はcapHeightより上に出るため、em枠で測る。
    /// em枠はベースラインの上0.88em、下0.12emにあるとみなす。
    static let emBoxAscent: CGFloat = 0.88
    static let emBoxDescent: CGFloat = 0.12

    /// 先頭の文字の、ベースラインから字面の上端まで。
    static func textTopInset(of text: NSAttributedString) -> CGFloat {
        guard text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return 0 }
        return font.pointSize * emBoxAscent
    }

    /// 最後の文字の、ベースラインから字面の下端まで。
    static func textBottomInset(of text: NSAttributedString) -> CGFloat {
        guard text.length > 0, let font = text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? UIFont else { return 0 }
        return font.pointSize * emBoxDescent
    }

    /// 読み上げで、注意書きの本文を開閉する操作。注意書きがなければnil。
    func spoilerAccessibilityAction() -> UIAccessibilityCustomAction? {
        guard let spoiler = content?.spoiler else { return nil }
        return UIAccessibilityCustomAction(name: SpoilerView.toggleTitle(isCollapsed: spoiler.isCollapsed, kind: spoiler.kind)) { [weak self] _ in
            self?.onToggleSpoiler?()
            return true
        }
    }

    /// 読み上げる文。注意書きがあれば先に読み、折りたたんでいる間は本文を読まない。フィルターの注記は別の要素なので含めない。
    var accessibilityText: String {
        guard let content else { return "" }
        guard let spoiler = content.spoiler else { return content.text.string }
        let label = switch spoiler.kind {
        case .contentWarning: "注意書き"
        // ボックスの文字が「フィルター: 名前」なので、重ねて読まない。
        case .filter: ""
        }
        let parts = [label, spoiler.text.string] + (spoiler.isCollapsed ? [] : [content.text.string])
        return parts.filter { !$0.isEmpty }.joined(separator: "、")
    }

    /// 行数で切る本文の末尾に、省略記号を出す。本文の段落は折り返しの指定を持ち、そのままでは最後の行が黙って切れるため。
    /// UILabelは、複数行のときの末尾の省略を折り返したうえで最後の行に当てる。
    private static func truncatingTail(_ text: NSAttributedString, when truncates: Bool) -> NSAttributedString {
        guard truncates else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.lineBreakMode = .byTruncatingTail
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    /// 読み上げで、本文のリンクを開く操作。
    func linkAccessibilityActions() -> [UIAccessibilityCustomAction] {
        guard let text = content?.text, content?.spoiler?.isCollapsed != true else { return [] }
        return LinkLabel.links(in: text).map { text, destination in
            UIAccessibilityCustomAction(name: text) { [weak self] _ in
                self?.onOpenLink?(destination)
                return true
            }
        }
    }
}
