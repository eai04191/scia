import SciaCore
import UIKit

/// 投稿の中身。投稿のセルと通知のセルで同じ部品を使い、どの部品をどう出すかは置く側が決める。
///
/// 上から、注意書き、本文、添付ファイル、リンクカードの順に並べる。投票、引用、編集済みの印は、部品ができたらここに足す。
/// 注意書きで畳んでいる間は、注意書きだけを出す。
/// 本文が空なら、本文と添付ファイルのあいだの余白も取らず、添付ファイルを上端から置く。上の行との間隔は置く側が`startsWithMedia`を見て決める。
struct PostBodyContent {
    struct Spoiler {
        /// 箱に入れて本文を畳むもの。
        enum Kind {
            /// 投稿した人が付けた注意書き。開閉できる。
            case contentWarning
            /// 使う人のフィルターに一致した警告。開いたら箱ごと消え、閉じ直さない。
            case filter
        }

        var text: NSAttributedString
        var isCollapsed: Bool
        var kind: Kind = .contentWarning
        /// 注意書きの箱の内側の余白。
        var padding: CGFloat
        /// 開いているときの、注意書きの箱と本文のあいだ。
        var bodySpacing: CGFloat
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
    /// リンクカードを出さなければnil。
    var card: LinkCardView.Content?
    /// 本文か添付ファイルと、リンクカードのあいだの余白。
    var cardSpacing: CGFloat = 0
    /// Xの投稿の囲み。あれば、リンクカードの代わりに同じ位置に置く。
    var xPost: XPostView.Content?
    /// 表示している投稿。リンクカードから囲みに替わったのが同じ投稿の行かを見分ける。同じXの投稿へのリンクは、別の投稿にもありうるため。
    var statusID: Status.ID?
    /// 自分の投稿が自分のフィルターに一致していることを示す1行。一番下に置く。一致していなければnil。
    var filterNote: NSAttributedString?
    /// 上の部品と、フィルターの印のあいだ。
    var filterNoteSpacing: CGFloat = 0
}

final class PostBodyView: UIView {
    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    /// 添付ファイルか、リンクカードの画像の、閲覧注意の覆いが押されたときに呼ぶ。覆いを外すのは置く側で、適用し直すまで見た目は変わらない。
    var onRevealMedia: (() -> Void)?
    /// 注意書きが押されたときに呼ぶ。開閉した状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onToggleSpoiler: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// リンクカードの画像がタップされたときに、ビューアを開閉する起点として、サムネイルを渡して呼ぶ。
    var onOpenLinkCardImage: ((LinkCardThumbnailView) -> Void)?
    /// Xの投稿の囲みのサムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectXPostMedia: ((Int, MediaGridView) -> Void)?

    private let spoilerView = SpoilerView()
    private let textLabel = LinkLabel()
    private let mediaView: MediaGridView
    private let cardView: LinkCardView
    private let xPostView: XPostView
    private let filterNoteLabel = UILabel()
    private(set) var content: PostBodyContent?
    /// 添付ファイルの有無と並べ方で変わる制約。適用のたびに作り直す。
    private var variableConstraints: [NSLayoutConstraint] = []

    /// 表示中のサムネイル。ビューアの拡大と縮小の起点を探すときに使う。
    var mediaGrid: MediaGridView? {
        mediaView.isHidden ? nil : mediaView
    }

    /// 表示中のリンクカード。読み上げの要素に加える。
    var linkCard: LinkCardView? {
        cardView.isHidden ? nil : cardView
    }

    /// 表示中のXの投稿の囲み。読み上げの要素に加え、ビューアの拡大と縮小の起点を探すときにも使う。
    var xPost: XPostView? {
        xPostView.isHidden ? nil : xPostView
    }

    /// 表示中のフィルターの印。添付ファイルやリンクカードより下にあるため、読み上げでは本文と分け、それらの後の要素にする。
    var filterNote: UILabel? {
        filterNoteLabel.isHidden ? nil : filterNoteLabel
    }

    /// 注意書きも本文もなく、添付ファイルが上端から始まる。
    var startsWithMedia: Bool {
        spoilerView.isHidden && textLabel.isHidden && !mediaView.isHidden
    }

    /// 注意書きと本文の枠。読み上げの要素の範囲を決めるときに使う。
    var textFrame: CGRect {
        [spoilerView, textLabel].filter { !$0.isHidden }.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    }

    /// 注意書きと本文のアニメーションするカスタム絵文字を動かすときに、アニメーション版を読む置き場。nilなら動かさない。
    var emojiImages: EmojiImageStore? {
        get { textLabel.emojiImages }
        set {
            textLabel.emojiImages = newValue
            spoilerView.emojiImages = newValue
        }
    }

    init(mediaImages: MediaImageStore, avatarImages: AvatarImageStore) {
        mediaView = MediaGridView(store: mediaImages)
        cardView = LinkCardView(store: mediaImages)
        xPostView = XPostView(store: mediaImages, avatarImages: avatarImages)
        super.init(frame: .zero)
        textLabel.numberOfLines = 0
        filterNoteLabel.numberOfLines = 0
        for view in [spoilerView, textLabel, mediaView, cardView, xPostView, filterNoteLabel] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            spoilerView.topAnchor.constraint(equalTo: topAnchor),
            spoilerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            spoilerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        mediaView.onSelect = { [weak self] index in
            guard let self else { return }
            self.onSelectMedia?(index, self.mediaView)
        }
        mediaView.onReveal = { [weak self] in self?.onRevealMedia?() }
        spoilerView.addAction(UIAction { [weak self] _ in self?.onToggleSpoiler?() }, for: .touchUpInside)
        textLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
        cardView.onOpenImage = { [weak self] thumbnail in self?.onOpenLinkCardImage?(thumbnail) }
        cardView.onRevealImage = { [weak self] in self?.onRevealMedia?() }
        cardView.addAction(UIAction { [weak self] _ in
            guard let self, let url = self.cardView.content?.card.url else { return }
            self.onOpenLink?(.url(url))
        }, for: .primaryActionTriggered)
        xPostView.onSelectMedia = { [weak self] index, grid in self?.onSelectXPostMedia?(index, grid) }
        xPostView.onRevealMedia = { [weak self] in self?.onRevealMedia?() }
        xPostView.onOpenLink = { [weak self] destination in self?.onOpenLink?(destination) }
        xPostView.addAction(UIAction { [weak self] _ in
            guard let self, let url = self.xPostView.content?.post.url else { return }
            self.onOpenLink?(.url(url))
        }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ content: PostBodyContent) {
        let previous = self.content
        self.content = content
        textLabel.attributedText = Self.truncatingTail(content.text, when: content.maximumLines > 0)
        textLabel.numberOfLines = content.maximumLines
        NSLayoutConstraint.deactivate(variableConstraints)
        variableConstraints = []
        if let spoiler = content.spoiler {
            spoilerView.isHidden = false
            spoilerView.apply(SpoilerView.Content(text: spoiler.text, isCollapsed: spoiler.isCollapsed, kind: spoiler.kind, padding: spoiler.padding))
        } else {
            spoilerView.isHidden = true
        }
        let isCollapsed = content.spoiler?.isCollapsed ?? false
        let media = isCollapsed ? nil : content.media.flatMap { $0.aspectRatio == nil ? nil : $0 }
        let xPost = isCollapsed ? nil : content.xPost
        let card = isCollapsed || xPost != nil ? nil : content.card
        textLabel.isHidden = isCollapsed || (content.text.length == 0 && (media != nil || card != nil || xPost != nil || content.spoiler != nil))
        // 本文と添付ファイルは、注意書きがあればその下から並べる。
        let contentTop = content.spoiler.map { (anchor: spoilerView.bottomAnchor, spacing: $0.bodySpacing) } ?? (anchor: topAnchor, spacing: 0)
        if !textLabel.isHidden {
            variableConstraints.append(textLabel.firstBaselineAnchor.constraint(equalTo: contentTop.anchor, constant: contentTop.spacing + Self.textTopInset(of: content.text)))
        }
        if let media, let aspectRatio = media.aspectRatio {
            mediaView.isHidden = false
            mediaView.apply(media)
            let mediaTop = textLabel.isHidden
                ? mediaView.topAnchor.constraint(equalTo: contentTop.anchor, constant: contentTop.spacing)
                : mediaView.topAnchor.constraint(equalTo: textLabel.lastBaselineAnchor, constant: content.mediaSpacing + Self.textBottomInset(of: content.text))
            variableConstraints += [
                mediaTop,
                mediaView.leadingAnchor.constraint(equalTo: leadingAnchor),
                mediaView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            let height = switch media.arrangement {
            case .grid: mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: 1 / aspectRatio)
            case .strip(let side): mediaView.heightAnchor.constraint(equalToConstant: side)
            }
            variableConstraints.append(height)
        } else {
            mediaView.isHidden = true
        }
        if let card {
            cardView.isHidden = false
            cardView.apply(card)
            let cardTop = if !mediaView.isHidden {
                cardView.topAnchor.constraint(equalTo: mediaView.bottomAnchor, constant: content.cardSpacing)
            } else if !textLabel.isHidden {
                cardView.topAnchor.constraint(equalTo: textLabel.lastBaselineAnchor, constant: content.cardSpacing + Self.textBottomInset(of: content.text))
            } else {
                cardView.topAnchor.constraint(equalTo: contentTop.anchor, constant: contentTop.spacing)
            }
            variableConstraints += [
                cardTop,
                cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
                cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        } else {
            cardView.isHidden = true
        }
        if let xPost {
            // 同じ投稿のリンクカードから替わったときだけ、囲みを浮かび上がらせる。行が伸びる動きは一覧が付ける。
            // 使い回された行で別の投稿に替わったときは、動かさずに出す。
            let replacesCard = previous?.xPost == nil && previous?.card != nil && content.statusID != nil && previous?.statusID == content.statusID
            let fadesIn = replacesCard && window != nil && xPost.transitionDuration > 0 && !UIAccessibility.isReduceMotionEnabled
            xPostView.isHidden = false
            xPostView.apply(xPost)
            xPostView.alpha = fadesIn ? 0 : 1
            if fadesIn {
                // 一覧は動きを止めて描き直すことがあり、その中ではUIView.animateが動かないため、描き直しを終えてから動かす。
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.content?.xPost == xPost else {
                        self?.xPostView.alpha = 1
                        return
                    }
                    UIView.animate(withDuration: xPost.transitionDuration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
                        self.xPostView.alpha = 1
                    }
                }
            }
            let xPostTop = if !mediaView.isHidden {
                xPostView.topAnchor.constraint(equalTo: mediaView.bottomAnchor, constant: content.cardSpacing)
            } else if !textLabel.isHidden {
                xPostView.topAnchor.constraint(equalTo: textLabel.lastBaselineAnchor, constant: content.cardSpacing + Self.textBottomInset(of: content.text))
            } else {
                xPostView.topAnchor.constraint(equalTo: contentTop.anchor, constant: contentTop.spacing)
            }
            variableConstraints += [
                xPostTop,
                xPostView.leadingAnchor.constraint(equalTo: leadingAnchor),
                xPostView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        } else {
            xPostView.isHidden = true
        }
        // 添付ファイルもリンクカードもないのに本文を隠すのは、注意書きがあるときだけ。
        let last: UIView = if !xPostView.isHidden {
            xPostView
        } else if !cardView.isHidden {
            cardView
        } else if !mediaView.isHidden {
            mediaView
        } else {
            textLabel.isHidden ? spoilerView : textLabel
        }
        if let note = content.filterNote {
            filterNoteLabel.isHidden = false
            filterNoteLabel.attributedText = note
            // 先頭の記号は画像の文字なので、読み上げでは除く。
            filterNoteLabel.accessibilityLabel = note.string.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFC}").union(.whitespaces))
            // 本文の下なら、ほかの部品と同じく字面の下端から測る。
            let lastBottom = last === textLabel
                ? (anchor: textLabel.lastBaselineAnchor, inset: Self.textBottomInset(of: content.text))
                : (anchor: last.bottomAnchor, inset: 0)
            variableConstraints += [
                filterNoteLabel.firstBaselineAnchor.constraint(equalTo: lastBottom.anchor, constant: lastBottom.inset + content.filterNoteSpacing + Self.textTopInset(of: note)),
                filterNoteLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                filterNoteLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                bottomAnchor.constraint(equalTo: filterNoteLabel.lastBaselineAnchor, constant: Self.textBottomInset(of: note)),
            ]
        } else {
            filterNoteLabel.isHidden = true
            variableConstraints.append(bottomAnchor.constraint(equalTo: last.bottomAnchor))
        }
        NSLayoutConstraint.activate(variableConstraints)
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

    /// 読み上げる文。注意書きがあれば先に読み、畳んでいる間は本文を読まない。フィルターの印は別の要素なので含めない。
    var accessibilityText: String {
        guard let content else { return "" }
        guard let spoiler = content.spoiler else { return content.text.string }
        let label = switch spoiler.kind {
        case .contentWarning: "注意書き"
        // 箱の文字が「フィルター: 名前」なので、重ねて読まない。
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

    /// 読み上げで、本文のリンクを開く操作。押しても何もしないハッシュタグは除く。
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
