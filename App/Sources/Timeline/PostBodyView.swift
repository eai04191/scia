import SciaCore
import TextKit2Label
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
    /// 本文が訳文ならfalse、訳文を待っている原文ならtrue。`text`の先頭の空き（`RichTextRenderer.marksTranslation`）に、翻訳のマークを重ねる。出さなければnil。
    var translationMarkPulses: Bool?
    /// `text`を先に並べた結果。先に並べていなければnil。
    var preparedLayout: PreparedTextLayout?
    /// 本文を切る行数。0なら切らない。
    var maximumLines = 0
    /// 長い本文を切って「続きを読む」を出す行数。nilなら切らない。`maximumLines`とは一緒に使わない。
    var truncation: BodyTruncation?
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
    /// 絵文字のリアクション。サーバーが対応していないか、リアクションがなければnil（docs/emoji-reaction.md）。
    var reactions: [ReactionChipsView.Reaction]?
    /// 上の部品と、リアクションの列のあいだ。
    var reactionsSpacing: CGFloat = 0
    var reactionsStyle = ReactionChipsView.Style.standard
    /// リアクションが付いた、なくなった、数が変わったときに動かす時間。0なら切り替える。
    var reactionsTransitionDuration: TimeInterval = 0
    /// 一番下に置く補足の1行。自分の投稿が自分のフィルターに一致していることか、通知で再掲する投稿に引用があることを示す。なければnil。
    var filterNote: NSAttributedString?
    /// 上の部品と、フィルターの注記のあいだ。
    var filterNoteSpacing: CGFloat = 0
    /// 一番下に置くアクションバー。出さなければnil（docs/post-action-bar.md）。
    var actionBar: PostActionBarContent?
    /// 上の部品と、アクションバーのあいだ。
    var actionBarSpacing: CGFloat = 0
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
    /// 囲みの切った本文の「続きを読む」が押されたときに呼ぶ。
    var expandBody: (() -> Void)?
}

final class PostBodyView: UIView {
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    /// 添付ファイルか、リンクカードの画像の、閲覧注意のぼかしが押されたときに呼ぶ。ぼかしを外すのは置く側で、適用し直すまで見た目は変わらない。
    var onRevealMedia: (() -> Void)?
    /// 注意書きが押されたときに呼ぶ。開閉した状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onToggleSpoiler: (() -> Void)?
    /// 切った本文の「続きを読む」が押されたときに呼ぶ。広げた状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onExpandBody: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// 本文と囲みの本文のリンクのタップで、タップと長押しの設定によらず、いつも開く（`LinkLabel.opensLinksOnTapOnly`）。
    var opensLinksOnTapOnly = false {
        didSet {
            textLabel.opensLinksOnTapOnly = opensLinksOnTapOnly
            embedView?.opensLinksOnTapOnly = opensLinksOnTapOnly
        }
    }
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
    /// リアクションのボタンが押されたときに、その絵文字の`Reaction.name`を渡して呼ぶ。
    var onToggleReaction: ((String) -> Void)?
    /// リアクションのボタンのタップと長押しの対象。絵文字の名前を渡して受け取る。
    var reactionTarget: ((String) -> (any ObjectActionTarget)?)?
    /// リアクションの列の「＋」が押されたときに呼ぶ。nilなら「＋」を出さない。
    var onAddReaction: (() -> Void)? {
        didSet { reactionsView?.showsAddButton = onAddReaction != nil }
    }

    private let mediaImages: MediaImageStore<UIImage>
    private let avatarImages: AvatarImageStore<UIImage>
    private let textLabel = LinkLabel()
    /// 本文の先頭の空きに重ねる、翻訳のマーク。
    private let translationMark = TranslationMarkView()
    /// 本文の最初と最後のベースラインの位置。本文の上下のすき間は字面から測るので、「投稿の見た目」のプレビューで字面の枠を求めるのに使う。
    /// 本文の上下の部品は、ラベルのベースラインではなく、この位置から置く。
    private let textFirstBaselineGuide = UILayoutGuide()
    private let textLastBaselineGuide = UILayoutGuide()
    /// ベースラインの位置を、TextKit 2で並べた結果からラベルの上下の端に合わせる制約。
    /// UILabelのベースライン（`firstBaselineAnchor`など）は、TextKit 2で並べた結果を使わずにUILabelが並べ直して求めるため、使わない。
    private lazy var textKitFirstBaseline = textFirstBaselineGuide.topAnchor.constraint(equalTo: textLabel.topAnchor)
    private lazy var textKitLastBaseline = textLastBaselineGuide.topAnchor.constraint(equalTo: textLabel.bottomAnchor)
    /// 本文の最初の文字の字面の上端と、最後の文字の字面の下端の位置。本文の上下の部品は、ここからすき間を取って置く。
    /// ベースラインからの距離（`textTopInset`、`textBottomInset`）は、行より広いカスタム絵文字を縮めて置くと並べる幅で変わるので、ベースラインと一緒に並べた幅で決め直す。
    private let textGlyphsTopGuide = UILayoutGuide()
    private let textGlyphsBottomGuide = UILayoutGuide()
    private lazy var textGlyphsTop = textFirstBaselineGuide.topAnchor.constraint(equalTo: textGlyphsTopGuide.topAnchor)
    private lazy var textGlyphsBottom = textGlyphsBottomGuide.topAnchor.constraint(equalTo: textLastBaselineGuide.topAnchor)
    /// 字面の上下の位置を決めた、本文の文字列と幅と、切って描くか。同じなら決め直さない。
    private var textGlyphsInsetsSource: (text: NSAttributedString, width: CGFloat, isTruncated: Bool)?
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
    /// 次に並べるときに動かす、本文より下の部品と前の上端、動きの時間。
    private var pendingBelowTextShift: (views: [(UIView, CGFloat)], duration: TimeInterval)?
    private var filterNoteLabel: UILabel?
    private var reactionsView: ReactionChipsView?
    private var actionBarView: PostActionBarView?
    /// アクションバーのボタンが押されたときに、その項目と、押したボタンを渡して呼ぶ。
    var onActionBarPress: ((PostActionBarItem, UIView) -> Void)?
    /// アクションバーのボタンを長押しして出すメニューの対象。
    var actionBarLongPressTarget: ((PostActionBarItem) -> (any ObjectActionTarget)?)? {
        didSet { actionBarView?.longPressTarget = actionBarLongPressTarget }
    }
    /// 今の`apply`で、リアクションの変化を動かすか。
    private var animatesReactionChange = false
    /// 「テキストを選択」で、本文のラベルの代わりに同じ位置に出している選べるテキストビュー。選んでいなければnil。
    private(set) var selectionTextView: SelectableTextView?
    /// 選んでいる間、本文のラベルに出している本文。サーバーが縮めて見せるURLを元の文字に戻したもの。戻すURLがないか、選んでいなければnil。
    private(set) var expandedText: NSAttributedString?
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

    /// 表示中のリアクションの列。読み上げの要素に加える。
    var reactions: ReactionChipsView? {
        Self.shown(reactionsView)
    }

    /// 表示中のアクションバー。読み上げの要素に加える。
    var actionBar: PostActionBarView? {
        Self.shown(actionBarView)
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
            .truncatedBody: textLabel.isTruncatedByLength ? textLabel.previewFrame(in: space) : nil,
            .readMore: textLabel.readMoreFrame.map { [textLabel.convert($0, to: space)] },
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
        frames.merge(reactionPreviewFrames(in: space)) { $1 }
        if let bar = actionBar {
            frames[.actionBar] = [bar.convert(bar.bounds, to: space)]
            frames[.actionBarIcons] = bar.iconFrames(in: space)
            frames[.actionBarPaddingBands] = bar.paddingBands(in: space)
            let counts = bar.countFrames(in: space)
            frames[.actionBarCounts] = counts.isEmpty ? nil : counts
        }
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
        let quoteBars = textLabel.quoteBarFrames().map { textLabel.convert($0, to: space) }
        frames[.quoteBars] = quoteBars.isEmpty ? nil : quoteBars
        let emojis = textLabel.previewCustomEmojiFrames().map { textLabel.convert($0, to: space) }
        frames[.customEmojis] = emojis.isEmpty ? nil : emojis
        let unicodeEmojis = textLabel.previewUnicodeEmojiFrames().map { textLabel.convert($0, to: space) }
        frames[.unicodeEmojis] = unicodeEmojis.isEmpty ? nil : unicodeEmojis
        if let text = textLabel.attributedText, text.length > 0, text.attribute(.emojiOnlyBody, at: 0, effectiveRange: nil) != nil {
            frames[.emojiOnlyBody] = [label]
            let all = emojis + unicodeEmojis
            frames[.emojiOnlyEmojis] = all.isEmpty ? nil : all
        }
        return frames
    }

    /// 本文の字面の枠。上端は最初のベースラインから、下端は最後のベースラインから、em枠で測る。並びも同じ測り方で、すき間を取っている。
    private func textGlyphsFrame(in space: UIView) -> [CGRect]? {
        guard let label = textLabel.previewFrame(in: space)?.first else { return nil }
        let top = convert(CGPoint(x: 0, y: textGlyphsTopGuide.layoutFrame.minY), to: space).y
        let bottom = convert(CGPoint(x: 0, y: textGlyphsBottomGuide.layoutFrame.minY), to: space).y
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
    var emojiImages: EmojiImageStore<UIImage>? {
        get { textLabel.emojiImages }
        set {
            textLabel.emojiImages = newValue
            spoilerView?.emojiImages = newValue
            pollView?.emojiImages = newValue
            embedView?.emojiImages = newValue
        }
    }

    init(mediaImages: MediaImageStore<UIImage>, avatarImages: AvatarImageStore<UIImage>) {
        self.mediaImages = mediaImages
        self.avatarImages = avatarImages
        super.init(frame: .zero)
        // 文字列を入れる前にTextKit 2で描くようにする。UILabelで描くままのラベルに長い本文を入れると、UILabelがその場で並べるため。
        textLabel.drawsWithTextKit = true
        textLabel.numberOfLines = 0
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)
        addSubview(translationMark)
        let textTrailing = textLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
        self.textTrailing = textTrailing
        NSLayoutConstraint.activate([textLabel.leadingAnchor.constraint(equalTo: leadingAnchor), textTrailing])
        for guide in [textFirstBaselineGuide, textLastBaselineGuide, textGlyphsTopGuide, textGlyphsBottomGuide, besideGuide, besideEndGuide] {
            addLayoutGuide(guide)
        }
        NSLayoutConstraint.activate([
            textFirstBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
            textLastBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
            textGlyphsTopGuide.heightAnchor.constraint(equalToConstant: 0),
            textGlyphsBottomGuide.heightAnchor.constraint(equalToConstant: 0),
            textKitFirstBaseline,
            textKitLastBaseline,
            textGlyphsTop,
            textGlyphsBottom,
        ])
        textLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
        textLabel.onExpand = { [weak self] in self?.onExpandBody?() }
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

    /// リアクションの列と、ボタンの中の余白とボタンのあいだの枠。
    private func reactionPreviewFrames(in space: UIView) -> AppearancePreviewFrames {
        guard let view = reactions else { return [:] }
        let chips = view.chipPreviewFrames(in: space)
        let padding = view.style.padding
        let thickness = AppearanceHighlight.minimumGapThickness
        var frames: AppearancePreviewFrames = [
            .reactions: [view.convert(view.bounds, to: space)],
            .reactionChips: chips,
            .reactionPaddingBands: chips.flatMap { chip in
                [
                    CGRect(x: chip.minX, y: chip.minY, width: chip.width, height: max(padding.top, thickness)),
                    CGRect(x: chip.minX, y: chip.maxY - max(padding.bottom, thickness), width: chip.width, height: max(padding.bottom, thickness)),
                ]
            },
            .reactionSidePaddingBands: chips.flatMap { chip in
                [
                    CGRect(x: chip.minX, y: chip.minY, width: max(padding.leading, thickness), height: chip.height),
                    CGRect(x: chip.maxX - max(padding.trailing, thickness), y: chip.minY, width: max(padding.trailing, thickness), height: chip.height),
                ]
            },
        ]
        if chips.count > 1 {
            frames[.reactionGaps] = AppearanceHighlight.gaps(between: chips)
        }
        return frames
    }

    /// リアクションがすべてなくなったときに、列の像をその場に残して、ボタンが消えるのと同じく縮めながら薄くして外す。
    /// 列は並びから外れて行が縮むので、像は行の下へはみ出し、タイムラインが下の行を上へ動かして覆う（`reconfigureShiftingRowsBelow`）。
    /// 動きは、次に並べるときに始める。タイムラインは行の中身を動きを止めた描き直しの中で当てるため、`apply`の中で始めた`UIView.animate`は効かない。
    private func fadeOutReactions(_ view: ReactionChipsView, duration: TimeInterval) {
        guard duration > 0, !UIAccessibility.isReduceMotionEnabled, let snapshot = view.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = view.frame
        snapshot.isUserInteractionEnabled = false
        addSubview(snapshot)
        reactionFadeOutSnapshots.append(snapshot)
        pendingReactionsFadeOut?.snapshot.removeFromSuperview()
        pendingReactionsFadeOut = (snapshot, duration)
        setNeedsLayout()
    }

    /// 次に並べるときに薄くして外す、なくなったリアクションの列の像。
    private var pendingReactionsFadeOut: (snapshot: UIView, duration: TimeInterval)?

    /// リアクションの列で続いている動きと、消えかけの列の像を外す。行が別の投稿に使い回されたときに、前の投稿の動きを残さないため。
    private func cancelReactionTransitions() {
        pendingReactionsFadeOut = nil
        for snapshot in reactionFadeOutSnapshots {
            snapshot.removeFromSuperview()
        }
        reactionFadeOutSnapshots.removeAll()
        reactionsView?.cancelTransitions()
    }

    /// 薄くしている途中の、なくなったリアクションの列の像。
    private var reactionFadeOutSnapshots: [UIView] = []

    private func startPendingReactionsFadeOut() {
        guard let (snapshot, duration) = pendingReactionsFadeOut else { return }
        pendingReactionsFadeOut = nil
        UIView.animate(springDuration: duration, bounce: 0, options: [.allowUserInteraction]) {
            snapshot.alpha = 0
            snapshot.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        } completion: { [weak self] _ in
            snapshot.removeFromSuperview()
            self?.reactionFadeOutSnapshots.removeAll { $0 === snapshot }
        }
    }

    private func loadedReactionsView() -> ReactionChipsView {
        if let reactionsView { return reactionsView }
        let view = ReactionChipsView()
        install(view)
        view.showsAddButton = onAddReaction != nil
        view.onToggle = { [weak self] name in self?.onToggleReaction?(name) }
        view.onAdd = { [weak self] in self?.onAddReaction?() }
        view.target = { [weak self] name in self?.reactionTarget?(name) }
        view.onHeightChange = { [weak self] in self?.invalidateRowHeight() }
        reactionsView = view
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
        view.opensLinksOnTapOnly = opensLinksOnTapOnly
        install(view)
        view.onSelectMedia = { [weak self] index, grid in self?.embedActions.selectMedia?(index, grid) }
        view.onRevealMedia = { [weak self] in self?.embedActions.revealMedia?() }
        view.onOpenLink = { [weak self] destination in self?.embedActions.openLink?(destination) }
        view.onOpenAccount = { [weak self] in self?.embedActions.openAccount?() }
        view.onToggleSpoiler = { [weak self] in self?.embedActions.toggleSpoiler?() }
        view.onHeightChange = { [weak self] in self?.invalidateRowHeight() }
        view.onSelectNote = { [weak self] index in self?.embedActions.selectNote?(index) }
        view.onExpandBody = { [weak self] in self?.embedActions.expandBody?() }
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

    private func loadedActionBarView() -> PostActionBarView {
        if let actionBarView { return actionBarView }
        let view = PostActionBarView()
        view.onPress = { [weak self] item, button in self?.onActionBarPress?(item, button) }
        view.longPressTarget = actionBarLongPressTarget
        install(view)
        actionBarView = view
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
        guard let content, !textLabel.isHidden, content.maximumLines == 0, !textLabel.isTruncatedByLength else { return false }
        return !content.text.stringWithoutTranslationMark.allSatisfy(\.isWhitespace)
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
    /// サーバーが縮めて見せるURLは、先にラベルを元の文字に戻した本文にしてから差し替える。
    func beginTextSelection() {
        guard canSelectText, selectionTextView == nil, let content else { return }
        showExpandedText(content.text.expandingCopiedLinks)
        guard let text = textLabel.textForTextKit else { return }
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
        if expandedText != nil, let content {
            expandedText = nil
            textLabel.attributedText = content.text
            textLabel.truncation = content.truncation
            textLabel.usePreparedLayout(content.preparedLayout)
            invalidateRowHeight()
        }
        onTextSelectionChange?()
    }

    /// 縮めたURLを元の文字に戻した本文があれば、ラベルをその本文にして、行の高さを測り直させる。
    /// 選べるのは切っていない本文だけなので、長い本文を切る決まりは外し、元の文字で伸びた分も切らずに出す。
    private func showExpandedText(_ expanded: NSAttributedString?) {
        guard let expanded else { return }
        expandedText = expanded
        textLabel.attributedText = expanded
        textLabel.truncation = nil
        textLabel.usePreparedLayout(nil)
        invalidateRowHeight()
    }

    /// 本文の高さが変わったので、置いているタイムラインの行に高さを測り直させる。行の上端は動かさず、下の行を動かす。
    private func invalidateRowHeight() {
        var view: UIView? = self
        while let current = view, !(current is UICollectionViewCell) {
            view = current.superview
        }
        view?.invalidateIntrinsicContentSize()
    }

    /// 本文の文字を別の文章へ入れ替える前に呼ぶ。文字の動きはラベルが付ける。本文より下の部品は、次に並べるときに、前の位置から新しい位置へ動かす。
    func prepareTextReplacement(duration: TimeInterval, shiftDuration: TimeInterval, wordDuration: TimeInterval, fadeWidth: Double) {
        textLabel.prepareTextReplacement(duration: duration, shiftDuration: shiftDuration, wordDuration: wordDuration, fadeWidth: fadeWidth)
        guard window != nil, shiftDuration > 0, !UIAccessibility.isReduceMotionEnabled else { return }
        let below = subviews.filter { $0 !== textLabel && $0.frame.minY >= textLabel.frame.maxY - 1 }
        pendingBelowTextShift = (below.map { ($0, $0.frame.minY) }, shiftDuration)
        setNeedsLayout()
    }

    /// 囲みの本文を別の文章へ入れ替える前に呼ぶ。囲みの中の動きは囲みが付ける。囲みより下の部品は、次に並べるときに、前の位置から新しい位置へ動かす。
    func prepareEmbedTextReplacement(shiftDuration: TimeInterval) {
        guard window != nil, shiftDuration > 0, !UIAccessibility.isReduceMotionEnabled, let embedView, !embedView.isHidden else { return }
        let below = subviews.filter { $0 !== embedView && $0.frame.minY >= embedView.frame.maxY - 1 }
        pendingBelowTextShift = (below.map { ($0, $0.frame.minY) }, shiftDuration)
        setNeedsLayout()
    }

    /// 本文より下の部品を、前の位置から今の位置へ動かす。段落の文字と、タイムラインの下の行と、同じ時刻に同じスプリングで動かす。
    private func startPendingBelowTextShift() {
        guard let (views, duration) = pendingBelowTextShift else { return }
        pendingBelowTextShift = nil
        for (view, oldMinY) in views {
            let shift = view.frame.minY - oldMinY
            guard view.superview === self, abs(shift) > 0.5 else { continue }
            let move = CASpringAnimation.rowSpring(keyPath: "position", duration: duration)
            move.isAdditive = true
            move.fromValue = CGPoint(x: 0, y: -shift)
            move.toValue = CGPoint.zero
            view.layer.add(move, forKey: "belowTextShift")
        }
    }

    func apply(_ content: PostBodyContent) {
        let previous = self.content
        defer {
            // 同じ投稿の描き直し（画像が届いた、数が変わったなど）では選んだままにし、別の投稿に替わったときと、本文が変わったか選べなくなったときにやめる。
            // 選んだままにするときも、絵文字の画像や絵文字そのものは替わりうるので、ラベルと同じ中身にそろえる。
            // 縮めたURLの隠した部分だけが編集されたときも、元のURLに戻して出している文字が変わり、選んだ範囲がずれるのでやめる。
            if isSelectingText {
                let expanded = content.text.expandingCopiedLinks
                if previous?.statusID != content.statusID || previous?.text.string != content.text.string || expanded?.string != expandedText?.string || !canSelectText {
                    endTextSelection()
                } else {
                    showExpandedText(expanded)
                    if let text = textLabel.textForTextKit {
                        selectionTextView?.replaceText(text)
                    }
                }
            }
        }
        self.content = content
        // 同じ投稿の描き直しで、画面に出ているときだけ、リアクションの変化を動かす。使い回したセルで別の投稿に替わったときは動かさない。
        animatesReactionChange = previous?.statusID != nil && previous?.statusID == content.statusID && window != nil
        if previous?.statusID != content.statusID {
            cancelReactionTransitions()
            textLabel.cancelTextReplacement()
            pendingBelowTextShift = nil
        }
        textLabel.attributedText = Self.truncatingTail(content.text, when: content.maximumLines > 0)
        textLabel.hashtagAccount = content.hashtagAccount
        // 長い本文を切るときは、行数をラベルが幅から決める。
        if content.truncation == nil {
            textLabel.numberOfLines = content.maximumLines
        }
        textLabel.truncation = content.truncation
        // ベースラインを置く前に、先に並べた結果を渡す。渡さないと、ベースラインを置くために、ここで並べることになる。
        textLabel.usePreparedLayout(content.preparedLayout)
        updateTextKitBaselines(width: textLabel.bounds.width > 0 ? textLabel.bounds.width : bounds.width)
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
        translationMark.apply(
            pulses: textLabel.isHidden || !content.text.hasTranslationMark ? nil : content.translationMarkPulses,
            keepsPulse: previous?.statusID == content.statusID && previous?.translationMarkPulses == true
        )
        // 本文と添付ファイルは、注意書きがあればその下から並べる。
        let contentTop = shownSpoiler?.bottomAnchor ?? topAnchor
        let contentTopSpacing = shownSpoiler == nil ? 0 : content.spoiler?.bodySpacing ?? 0
        let text = textLabel.isHidden ? nil : textGlyphsBottomGuide.topAnchor
        if !textLabel.isHidden {
            variableConstraints.append(textGlyphsTopGuide.topAnchor.constraint(equalTo: contentTop, constant: contentTopSpacing))
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
        let bottom = applyReactions(content.reactions, style: content.reactionsStyle, below: last, spacing: content.reactionsSpacing)
        let noteBottom = applyFilterNote(content.filterNote, below: bottom, spacing: content.filterNoteSpacing)
        applyActionBar(content.actionBar, below: noteBottom, spacing: content.actionBarSpacing)
        NSLayoutConstraint.activate(variableConstraints)
    }

    /// リアクションの列を一番下の部品の下に置き、新しい一番下を返す。注意書きで折りたたんでいても出す。リアクションは投稿に付くもので、中身を開かなくても見られるため。
    private func applyReactions(_ reactions: [ReactionChipsView.Reaction]?, style: ReactionChipsView.Style, below bottom: Bottom, spacing: CGFloat) -> Bottom {
        let duration = content?.reactionsTransitionDuration ?? 0
        guard let reactions, !reactions.isEmpty else {
            if let reactionsView, !reactionsView.isHidden {
                if animatesReactionChange {
                    fadeOutReactions(reactionsView, duration: duration)
                }
                // 次に付いたときに、どのボタンも新しく付いたものとして浮かび上がらせるため、空にしておく。
                reactionsView.apply([], style: style)
                reactionsView.isHidden = true
            }
            return bottom
        }
        let view = loadedReactionsView()
        view.isHidden = false
        view.animatedEmojis = emojiImages
        view.transitionDuration = duration
        // 幅が決まる前に高さを測るときは、本文と同じく、先に並べた幅か十分に広い幅で測る。
        view.widthHint = bounds.width > 0 ? bounds.width : textLabel.preparedLayoutWidth ?? Self.unknownTextWidth
        view.apply(reactions, style: style, animated: animatesReactionChange)
        let lastBottom = bottomEdge(of: bottom)
        variableConstraints.append(view.topAnchor.constraint(equalTo: lastBottom.anchor, constant: lastBottom.inset + spacing))
        return .view(view)
    }

    /// 本文の下の部品を縦に並べるときの、上端の決め方。
    @MainActor
    private struct Placement {
        /// 本文と添付ファイルを並べ始める位置。注意書きがあればその下。
        let contentTop: NSLayoutYAxisAnchor
        let contentTopSpacing: CGFloat
        /// 出している本文の、最後の文字の字面の下端。本文を出していなければnil。
        let text: NSLayoutYAxisAnchor?
        /// 添付ファイルを本文の右に出すとき、本文の字面とサムネイルの下端のうち、下にあるほう。出さなければnil。
        let besideBottom: NSLayoutYAxisAnchor?

        /// 上の部品の下端から、次の部品を置く位置。本文の下なら、字面の下端から測る。本文の右に添付ファイルがあれば、その下端とも比べる。
        func top(of view: UIView, below shownAbove: UIView?, spacing: CGFloat) -> NSLayoutConstraint {
            if let shownAbove {
                view.topAnchor.constraint(equalTo: shownAbove.bottomAnchor, constant: spacing)
            } else if let besideBottom {
                view.topAnchor.constraint(equalTo: besideBottom, constant: spacing)
            } else if let text {
                view.topAnchor.constraint(equalTo: text, constant: spacing)
            } else {
                view.topAnchor.constraint(equalTo: contentTop, constant: contentTopSpacing)
            }
        }
    }

    /// 本文を`width`で並べた結果から、ベースラインの位置をラベルの上下の端からの距離で、字面の上下の位置をベースラインからの距離で決める。
    /// 中身を適用するときはまだ本文の幅が決まっていないことがあるので、前の幅か自分の幅で決め、並べたあとに本文の幅で決め直す。
    /// 決め直して変わるのは、幅で最初か最後の行に入る文字の書体が替わり、行の高さが変わるときと、行より広いカスタム絵文字の縮め方が変わるときだけ。
    /// - Returns: 字面の上下の位置が変わったか。
    @discardableResult
    private func updateTextKitBaselines(width: CGFloat) -> Bool {
        // 初めて中身を入れるときは、まだ幅が決まっていない。十分に広い幅で並べて決め、高さを測る前にベースラインを置いておく。
        // 0のままにすると、ベースラインがラベルの上端に重なり、並べ直すまで本文が上へずれた高さで測られる。
        // 先に並べてあれば、並べた幅で決める。タイムラインの本文は、ふつうその幅に並ぶ。
        let width = width > 0 ? width : textLabel.preparedLayoutWidth ?? Self.unknownTextWidth
        let baselines = textLabel.textKitBaselines(width: width)
        if textKitFirstBaseline.constant != baselines.first {
            textKitFirstBaseline.constant = baselines.first
        }
        if textKitLastBaseline.constant != -baselines.lastFromBottom {
            textKitLastBaseline.constant = -baselines.lastFromBottom
        }
        return updateTextGlyphsInsets(width: width)
    }

    /// 字面の上下の位置を、本文を`width`で並べたときのベースラインからの距離で決める。文字列と幅が前と同じなら測り直さない。
    /// - Returns: 字面の上下の位置が変わったか。
    private func updateTextGlyphsInsets(width: CGFloat) -> Bool {
        guard let content else { return false }
        let isTruncated = content.maximumLines > 0
        if let source = textGlyphsInsetsSource, source.text === content.text, source.width == width, source.isTruncated == isTruncated { return false }
        textGlyphsInsetsSource = (content.text, width, isTruncated)
        let lines = textLabel.textKitLineRanges(of: content.text, width: width)
        let top = Self.textTopInset(of: content.text, width: width, firstLine: lines?.first)
        let bottom = Self.textBottomInset(of: content.text, isTruncated: isTruncated, width: width, lastLine: lines?.last)
        guard textGlyphsTop.constant != top || textGlyphsBottom.constant != bottom else { return false }
        textGlyphsTop.constant = top
        textGlyphsBottom.constant = bottom
        return true
    }

    /// 本文の幅が決まる前に、ベースラインを決めるために並べる幅。
    private static let unknownTextWidth: CGFloat = 10_000

    override func layoutSubviews() {
        super.layoutSubviews()
        translationMark.layout(over: textLabel, in: self)
        // 行より広いカスタム絵文字の縮め方が、中身を適用したときに見込んだ幅と違えば、字面の上下の位置が変わり、本文の高さも変わるので、タイムラインの行に測り直させる。
        if updateTextKitBaselines(width: textLabel.bounds.width) {
            invalidateRowHeight()
        }
        startPendingReactionsFadeOut()
        startPendingBelowTextShift()
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
    private func applyBesideMedia(_ media: MediaGridView.Content, side: CGFloat, top: NSLayoutYAxisAnchor, topSpacing: CGFloat, text: NSLayoutYAxisAnchor?) -> (parts: NSLayoutYAxisAnchor, end: NSLayoutYAxisAnchor) {
        let mediaView = loadedMediaView()
        mediaView.isHidden = false
        mediaView.apply(media)
        variableConstraints += [
            mediaView.topAnchor.constraint(equalTo: top, constant: topSpacing),
            mediaView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mediaView.widthAnchor.constraint(equalToConstant: side),
            mediaView.heightAnchor.constraint(equalToConstant: side),
        ]
        let mediaBottom = mediaView.bottomAnchor
        let textGlyphsBottom = text
        let textLabelBottom = text.map { _ in textLabel.bottomAnchor }
        variableConstraints += lowestBottom(besideGuide, top: top, of: [mediaBottom, textGlyphsBottom].compactMap(\.self))
        variableConstraints += lowestBottom(besideEndGuide, top: top, of: [mediaBottom, textLabelBottom].compactMap(\.self))
        return (besideGuide.bottomAnchor, besideEndGuide.bottomAnchor)
    }

    /// `guide`の下端を、`bottoms`のうち一番下にあるものに合わせる。上端を`top`に置いて高さをできるだけ縮めるので、どれよりも下で一番上の位置に決まる。
    private func lowestBottom(_ guide: UILayoutGuide, top: NSLayoutYAxisAnchor, of bottoms: [NSLayoutYAxisAnchor]) -> [NSLayoutConstraint] {
        // 本文のラベルの縮みにくさ（`.defaultHigh`）より低くする。同じだと、ラベルを縮めてサムネイルの高さで本文を切ってしまう。
        let collapse = guide.heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        return [guide.topAnchor.constraint(equalTo: top), collapse] + bottoms.map {
            guide.bottomAnchor.constraint(greaterThanOrEqualTo: $0)
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
    ///   行が伸びる動きはタイムラインが付ける。使い回された行で別の投稿に替わったときは、動かさずに出す。
    /// - Parameter keepsFade: 同じ投稿の囲みを描き直すだけ。浮かび上がらせている途中なら、その濃さのまま動かし続ける。
    private func applyEmbed(_ embed: EmbeddedPostView.Content?, fadesIn: Bool, keepsFade: Bool, leavingCard: UIView?, below shownAbove: UIView?, spacing: CGFloat, placement: Placement) -> EmbeddedPostView? {
        guard let embed else {
            embedView?.isHidden = true
            return nil
        }
        let embedView = loadedEmbedView()
        embedView.isHidden = false
        embedView.apply(embed)
        // タイムラインは行の高さを動かす動きの中で描き直すため、その動きに乗せず、すぐ消す。乗せると、濃い状態から薄くなる途中で
        // 濃くし始め、1コマで囲みが出て見える。濃くしている途中の行が別の投稿に使い回されたときも、その動きを止める。
        if fadesIn {
            embedView.stopFading(at: 0)
        } else if !keepsFade {
            embedView.stopFading(at: 1)
        }
        if fadesIn {
            let statusID = content?.statusID
            // タイムラインは動きを止めて描き直すことがあり、その中ではUIView.animateが動かないため、描き直しを終えてから動かす。
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
        // タイムラインは行の高さを動かす動きの中で描き直すため、像の置き場所がその動きに乗って左上から動かないよう、動きの外で置く。
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
        /// 文字の1行（フィルターの注記）。下端は、最後のベースラインから`bottomInset`だけ下の字面の下端。
        case text(UILabel, bottomInset: CGFloat)
    }

    /// フィルターの注記を一番下の部品の下に置き、新しい一番下を返す。
    private func applyFilterNote(_ note: NSAttributedString?, below bottom: Bottom, spacing: CGFloat) -> Bottom {
        guard let note else {
            filterNoteLabel?.isHidden = true
            return bottom
        }
        let filterNoteLabel = loadedFilterNoteLabel()
        filterNoteLabel.isHidden = false
        filterNoteLabel.attributedText = note
        // 先頭の記号は画像の文字なので、読み上げでは除く。
        filterNoteLabel.accessibilityLabel = note.string.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFC}").union(.whitespaces))
        let lastBottom = bottomEdge(of: bottom)
        variableConstraints.append(filterNoteLabel.firstBaselineAnchor.constraint(equalTo: lastBottom.anchor, constant: lastBottom.inset + spacing + Self.textTopInset(of: note)))
        return .text(filterNoteLabel, bottomInset: Self.textBottomInset(of: note))
    }

    /// アクションバーを一番下の部品の下に置き、自分の下端を決める。注意書きで折りたたんでいても出す。投稿への操作で、中身を開かなくても使えるため。
    private func applyActionBar(_ bar: PostActionBarContent?, below bottom: Bottom, spacing: CGFloat) {
        let lastBottom = bottomEdge(of: bottom)
        guard let bar else {
            actionBarView?.isHidden = true
            // 本文の右に添付ファイルがあれば、本文のラベルとサムネイルの下にあるほうを下端にする。
            let end: NSLayoutYAxisAnchor = switch bottom {
            case .view(let last): last.bottomAnchor
            case .beside(_, let end): end
            case .text(let label, _): label.lastBaselineAnchor
            }
            let inset: CGFloat = if case .text(_, let inset) = bottom { inset } else { 0 }
            variableConstraints.append(bottomAnchor.constraint(equalTo: end, constant: inset))
            return
        }
        let view = loadedActionBarView()
        view.isHidden = false
        view.apply(bar)
        variableConstraints += [
            view.topAnchor.constraint(equalTo: lastBottom.anchor, constant: lastBottom.inset + spacing),
            bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
    }

    /// 一番下の部品の下端。本文の下なら、ほかの部品と同じく字面の下端から測る。
    private func bottomEdge(of bottom: Bottom) -> (anchor: NSLayoutYAxisAnchor, inset: CGFloat) {
        switch bottom {
        case .view(let last) where last === textLabel: (anchor: textGlyphsBottomGuide.topAnchor, inset: 0)
        case .view(let last): (anchor: last.bottomAnchor, inset: 0)
        case .beside(let parts, _): (anchor: parts, inset: 0)
        case .text(let label, let inset): (anchor: label.lastBaselineAnchor, inset: inset)
        }
    }

    /// 和文の字面の枠（em枠）の、ベースラインから上端と下端までの距離。日本語の字面はcapHeightより上に出るため、em枠で測る。
    /// em枠はベースラインの上0.88em、下0.12emにあるとみなす。
    nonisolated static let emBoxAscent: CGFloat = 0.88
    nonisolated static let emBoxDescent: CGFloat = 0.12

    /// 先頭の文字の、ベースラインから字面の上端まで。絵文字が字面より上へ伸びていれば、その上端まで。
    /// 絵文字を文字の行より大きくした段落は、絵文字が字面の中心から上下へ伸び、行が文字の行より高くなる。
    /// 字面だけで測ると、1行目の絵文字が上の部品（名前の行）に重なるため、絵文字の上端で測る。
    /// 字面に、書体のascenderを超えた分だけを足すと、ascenderが字面より高いぶん絵文字の上端に届かず、上の部品との間隔が設定より狭くなる。
    /// UILabelで描くラベルは段落のどの行も同じ高さに広げるので（`RichTextRenderer`の`minimumLineHeight`）、絵文字が1行目になくても最初の段落の絵文字で測る。
    /// 段落の中の改行で区切った行は、高さが違えば`RichTextRenderer`が段落に分けるので、最初の段落は改行の前の行だけになる。
    /// - Parameter width: 並べる幅。渡せば、行より広いカスタム絵文字は縮めて置く大きさで測る。
    /// - Parameter firstLine: TextKit 2で並べた最初の行の文字の範囲（`TextKitLabel.textKitLineRanges(of:width:)`）。TextKit 2は行ごとに高さを決めるので、渡せばその行の絵文字で測る。
    static func textTopInset(of text: NSAttributedString, width: CGFloat? = nil, firstLine: NSRange? = nil) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let range = firstLine ?? (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        guard let font = RichTextRenderer.textFont(in: text, range: range) else { return 0 }
        return max(font.pointSize * emBoxAscent, RichTextRenderer.emojiExtent(in: text, range: range, width: width).above)
    }

    /// 最後の文字の、ベースラインから字面の下端まで。最後の段落の絵文字が字面より下へ伸びていれば、その下端まで。
    /// - Parameter isTruncated: 行数で切って描くときはtrue。最後に見える行がどの段落か分からないため、全体の絵文字で測る。
    ///   切れた先にだけ大きい絵文字があると、下の部品とのあいだが絵文字の分だけ広く空くが、重なるよりよいので受け入れる。
    ///   長い本文を切る決まり（`PostBodyContent.truncation`）では、falseのまま最後の段落で測る。切るかどうかは並べる幅で決まるため、
    ///   全体で測ると、切っていないほとんどの投稿でも途中の段落の絵文字の分だけ下の部品とのあいだが広がる。切ったときは、見える最後の行に、
    ///   最後の段落より下へ伸びる大きい絵文字があると、その差の分だけ下の部品に近づく。幅が分かるのは並べるときで、あいだの制約を作る中身の適用では分からず、
    ///   並べるときに制約を変えると、行の高さがタイムラインの測った高さと食い違うため、対応しない。
    /// - Parameter width: 並べる幅。渡せば、行より広いカスタム絵文字は縮めて置く大きさで測る。
    /// - Parameter lastLine: TextKit 2で並べた最後の行の文字の範囲（`TextKitLabel.textKitLineRanges(of:width:)`）。渡せばその行の絵文字で測る。`isTruncated`なら使わない。
    static func textBottomInset(of text: NSAttributedString, isTruncated: Bool = false, width: CGFloat? = nil, lastLine: NSRange? = nil) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let range = isTruncated
            ? NSRange(location: 0, length: text.length)
            : lastLine ?? (text.string as NSString).paragraphRange(for: NSRange(location: text.length - 1, length: 0))
        guard let font = RichTextRenderer.textFont(in: text, range: range, fromEnd: true) else { return 0 }
        return max(font.pointSize * emBoxDescent, RichTextRenderer.emojiExtent(in: text, range: range, width: width).below)
    }

    /// 本文を先に並べるときに使う、本文のラベルの値と幅。本文を出していないとき、添付ファイルを本文の右に並べて幅を狭めているとき、幅が決まる前はnil。
    var bodyTextGeometry: BodyTextPreparer.Geometry? {
        guard !textLabel.isHidden, textLabel.bounds.width > 0, textTrailing?.constant ?? 0 == 0 else { return nil }
        return BodyTextPreparer.Geometry(style: textLabel.textKitStyle, width: textLabel.bounds.width)
    }

    /// 長い本文を、今の幅で切っている。
    var isBodyTruncated: Bool {
        !textLabel.isHidden && textLabel.isTruncatedByLength
    }

    /// 読み上げで、切った本文を広げる操作。切っていなければnil。
    func readMoreAccessibilityAction() -> UIAccessibilityCustomAction? {
        guard isBodyTruncated else { return nil }
        return UIAccessibilityCustomAction(name: ReadMoreButton.title) { [weak self] _ in
            self?.onExpandBody?()
            return true
        }
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
        guard let spoiler = content.spoiler else { return content.text.stringWithoutTranslationMark }
        let label = switch spoiler.kind {
        case .contentWarning: "注意書き"
        // ボックスの文字が「フィルター: 名前」なので、重ねて読まない。
        case .filter: ""
        }
        let parts = [label, spoiler.text.string] + (spoiler.isCollapsed ? [] : [content.text.stringWithoutTranslationMark])
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
