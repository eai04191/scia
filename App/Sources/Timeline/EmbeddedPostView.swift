import SciaCore
import UIKit

/// 投稿の本文の下に置く、ほかの投稿の囲み。Mastodonの引用と、fxtwitterから読んだXの投稿に使う。決まりは`docs/quote.md`と`docs/link-card.md`。
///
/// 上から、作者の行、注意書き、本文、添付ファイル、補足の行を並べる。引用元を出せないときは、作者の行を出さず、理由の1行だけを本文として出す。
/// 添付ファイルを重ねて出すときは、本文の右に置き、本文はその分をあけて折り返す。補足の行は、本文とサムネイルのどちらよりも下に置く。決まりは`docs/timeline-media.md`。
/// 囲みのどこかが押されたら、置く側が決めた先を開く。アイコン、注意書き、サムネイル、本文のリンク、押せる補足の行の押下は、並べた部品が受ける。
final class EmbeddedPostView: UIButton {
    struct Content: Equatable {
        /// 作者の行。出せない理由だけを出すときはnil。
        struct Header: Equatable {
            var avatar: AvatarView.Content
            /// 作者の行の文字。名前は太く、`@`から始まる名前は控えめに描く。
            var name: NSAttributedString
            /// アイコンを押してプロフィールを開けるか。
            var opensAccount: Bool
        }

        /// 本文と添付ファイルの下に並べる1行。引用元の投票や、引用元がさらに引用していることを示す。
        struct Note: Equatable {
            var text: NSAttributedString
            /// 押せる見た目にし、押下を囲みに渡さず受ける。
            var isPressable: Bool
        }

        /// 中身を見分ける。リンクカードから替わったのが同じ囲みかを比べるのに使う。
        var id: String
        var header: Header?
        var avatarSize: CGFloat
        /// 注意書きかフィルターの警告。折りたたんでいる間は、本文、添付ファイル、補足の行を出さない。
        var spoiler: SpoilerView.Content?
        var text: NSAttributedString
        /// 添付ファイルがなければnil。
        var media: MediaGridView.Content?
        var notes: [Note] = []
        /// 囲みを押して開けるか。開けなければ押下を受けず、行に渡す。
        var isPressable = true
        /// 読み上げで、囲みを押す操作の名前。
        var openActionName: String
        /// 囲みの内側の余白。
        var padding: CGFloat
        /// 作者のアイコンと名前のすき間。
        var avatarNameSpacing: CGFloat
        /// 作者の行と本文のあいだ。
        var headerSpacing: CGFloat
        /// 本文、添付ファイル、補足の行のあいだ。
        var mediaSpacing: CGFloat
        /// リンクカードから替わったときに、囲みを浮かび上がらせる時間。
        var transitionDuration: TimeInterval
    }

    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    /// 閲覧注意のぼかしが押されたときに呼ぶ。
    var onRevealMedia: (() -> Void)?
    /// 本文のリンクがタップされたときに、その行き先を渡して呼ぶ。
    var onOpenLink: ((RichText.LinkDestination) -> Void)?
    /// 作者のアイコンがタップされたときに呼ぶ。
    var onOpenAccount: (() -> Void)?
    /// 作者のアイコンのタップと長押し。渡すと、タップは`onOpenAccount`の代わりにこれで行い、長押しではその人のユーザーのメニューか、選んだ操作を行う。
    /// 決まりはdocs/object-actions.mdにある。読み上げの操作は、`onOpenAccount`のまま。
    var accountTarget: (any ObjectActionTarget)? {
        didSet { accountInteraction?.target = accountTarget }
    }
    private var accountInteraction: ObjectInteraction?
    /// 注意書きが押されたときに呼ぶ。開閉した状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onToggleSpoiler: (() -> Void)?
    /// 押せる補足の行がタップされたときに、何番目の行かを渡して呼ぶ。
    var onSelectNote: ((Int) -> Void)?

    private let avatarView: AvatarView
    private let nameLabel = EmojiLabel()
    private let spoilerView = SpoilerView()
    private let textLabel = LinkLabel()
    private let mediaView: MediaGridView
    private var noteViews: [NoteRow] = []
    /// アイコンと名前を並べる作者の行。
    private let headerGuide = UILayoutGuide()
    /// 添付ファイルを本文の右に出すとき、本文とサムネイルの下端のうち、下にあるほう。補足の行をここから並べる。
    private let besideGuide = UILayoutGuide()
    private(set) var content: Content?
    private var variableConstraints: [NSLayoutConstraint] = []
    private lazy var summaryElement = UIAccessibilityElement(accessibilityContainer: self)

    /// 名前、注意書き、本文のアニメーションするカスタム絵文字を動かすときに、アニメーション版を読み込むストア。nilなら動かさない。
    var emojiImages: EmojiImageStore<UIImage>? {
        get { textLabel.emojiImages }
        set {
            textLabel.emojiImages = newValue
            nameLabel.emojiImages = newValue
            spoilerView.emojiImages = newValue
        }
    }

    /// 表示中のサムネイル。ビューアの拡大と縮小の起点を探すときに使う。
    var mediaGrid: MediaGridView? {
        mediaView.isHidden ? nil : mediaView
    }

    init(store: MediaImageStore<UIImage>, avatarImages: AvatarImageStore<UIImage>) {
        mediaView = MediaGridView(store: store)
        avatarView = AvatarView(store: avatarImages)
        super.init(frame: .zero)
        layer.cornerRadius = MediaGridView.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        // 読み上げでは、囲みそのものではなく、まとめた要素とサムネイル、押せる補足の行を読む。
        isAccessibilityElement = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isUserInteractionEnabled = false
        textLabel.numberOfLines = 0
        // 本文はリンクの上だけ押下を受ける。リンクの外の押下は、囲みのボタンが受ける。
        textLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))
        accountInteraction = ObjectInteraction(on: avatarView, tapsSelf: false, lift: .shape)
        spoilerView.addAction(UIAction { [weak self] _ in self?.onToggleSpoiler?() }, for: .touchUpInside)
        for view in [avatarView, nameLabel, spoilerView, textLabel, mediaView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addLayoutGuide(headerGuide)
        addLayoutGuide(besideGuide)
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

    @objc private func avatarTapped(_ gesture: UITapGestureRecognizer) {
        guard let accountTarget, let view = gesture.view else {
            openAccount()
            return
        }
        accountTarget.perform(.tap, in: view, at: gesture.location(in: view))
    }

    private func openAccount() {
        onOpenAccount?()
    }

    func apply(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        NSLayoutConstraint.deactivate(variableConstraints)
        let padding = content.padding
        var constraints: [NSLayoutConstraint] = []
        // 次の部品を置く位置。部品を置くたびに下へ進める。
        var last: (anchor: NSLayoutYAxisAnchor, spacing: CGFloat) = (topAnchor, padding)

        if let header = content.header {
            avatarView.isHidden = false
            nameLabel.isHidden = false
            avatarView.apply(header.avatar)
            avatarView.isUserInteractionEnabled = header.opensAccount
            nameLabel.attributedText = header.name
            // 作者の行の高さは、アイコンと名前の高いほう。どちらも行の上下中央に揃える。
            let compactHeader = headerGuide.heightAnchor.constraint(equalToConstant: 0)
            // 下限だけでは高さが決まらないため、収まる最小の高さに寄せる。
            compactHeader.priority = .defaultLow
            constraints += [
                headerGuide.topAnchor.constraint(equalTo: last.anchor, constant: last.spacing),
                headerGuide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                headerGuide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
                headerGuide.heightAnchor.constraint(greaterThanOrEqualToConstant: content.avatarSize),
                compactHeader,
                nameLabel.topAnchor.constraint(greaterThanOrEqualTo: headerGuide.topAnchor),
                nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: headerGuide.bottomAnchor),
                avatarView.leadingAnchor.constraint(equalTo: headerGuide.leadingAnchor),
                avatarView.centerYAnchor.constraint(equalTo: headerGuide.centerYAnchor),
                avatarView.widthAnchor.constraint(equalToConstant: content.avatarSize),
                avatarView.heightAnchor.constraint(equalToConstant: content.avatarSize),
                nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: content.avatarNameSpacing),
                nameLabel.trailingAnchor.constraint(equalTo: headerGuide.trailingAnchor),
                nameLabel.centerYAnchor.constraint(equalTo: headerGuide.centerYAnchor),
            ]
            last = (headerGuide.bottomAnchor, content.headerSpacing)
        } else {
            avatarView.isHidden = true
            nameLabel.isHidden = true
        }

        if let spoiler = content.spoiler {
            spoilerView.isHidden = false
            spoilerView.apply(spoiler)
            constraints += horizontalConstraints(of: spoilerView, padding: padding)
            constraints.append(spoilerView.topAnchor.constraint(equalTo: last.anchor, constant: last.spacing))
            last = (spoilerView.bottomAnchor, content.mediaSpacing)
        } else {
            spoilerView.isHidden = true
        }
        let isCollapsed = content.spoiler?.isCollapsed ?? false
        let media = isCollapsed ? nil : content.media.flatMap { $0.aspectRatio == nil ? nil : $0 }
        let besideSide: CGFloat? = if case .stack(let side)? = media?.arrangement { side } else { nil }
        // 本文と、本文の右に出すサムネイルの上端。本文がなくても、サムネイルは本文があるときの位置に置く。
        let contentTop = last

        textLabel.attributedText = content.text
        textLabel.isHidden = isCollapsed || content.text.length == 0
        if !textLabel.isHidden {
            constraints += [
                textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                textLabel.topAnchor.constraint(equalTo: last.anchor, constant: last.spacing),
            ]
            // 本文の右にサムネイルを出すときの右端は、サムネイルの左に合わせる。
            if besideSide == nil {
                constraints.append(textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding))
            }
            last = (textLabel.bottomAnchor, content.mediaSpacing)
        }

        if let media, let besideSide {
            constraints += applyBesideMedia(media, side: besideSide, spacing: content.mediaSpacing, padding: padding, top: contentTop, text: content.text)
            last = (besideGuide.bottomAnchor, content.mediaSpacing)
        } else if let media, let aspectRatio = media.aspectRatio {
            mediaView.isHidden = false
            mediaView.apply(media)
            constraints += horizontalConstraints(of: mediaView, padding: padding)
            constraints += [
                mediaView.topAnchor.constraint(equalTo: last.anchor, constant: last.spacing),
                mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: 1 / aspectRatio),
            ]
            last = (mediaView.bottomAnchor, content.mediaSpacing)
        } else {
            mediaView.isHidden = true
        }

        let notes = isCollapsed ? [] : content.notes
        while noteViews.count < notes.count {
            let row = NoteRow()
            let index = noteViews.count
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addAction(UIAction { [weak self] _ in self?.onSelectNote?(index) }, for: .touchUpInside)
            addSubview(row)
            noteViews.append(row)
        }
        for (index, row) in noteViews.enumerated() {
            guard notes.indices.contains(index) else {
                row.isHidden = true
                continue
            }
            row.isHidden = false
            row.apply(notes[index])
            constraints += horizontalConstraints(of: row, padding: padding)
            constraints.append(row.topAnchor.constraint(equalTo: last.anchor, constant: last.spacing))
            last = (row.bottomAnchor, content.mediaSpacing)
        }

        constraints.append(bottomAnchor.constraint(equalTo: last.anchor, constant: padding))
        variableConstraints = constraints
        NSLayoutConstraint.activate(constraints)
        updateAccessibility(for: content)
    }

    /// 添付ファイルを本文の右に、一辺`side`の正方形で出し、本文はその左に`spacing`をあけて折り返す。上端は本文の1行目の字面の上端にそろえ、本文がなければ本文のラベルの上端に置く。
    /// 囲みは投稿の本文より狭いので、サムネイルとすき間は囲みの内側の半分までに縮め、本文の幅を残す。
    /// `besideGuide`の下端を、本文のラベルとサムネイルの下端のうち、下にあるほうに合わせる。
    private func applyBesideMedia(_ media: MediaGridView.Content, side: CGFloat, spacing: CGFloat, padding: CGFloat, top: (anchor: NSLayoutYAxisAnchor, spacing: CGFloat), text: NSAttributedString) -> [NSLayoutConstraint] {
        mediaView.isHidden = false
        mediaView.apply(media)
        let mediaTop = if textLabel.isHidden {
            mediaView.topAnchor.constraint(equalTo: top.anchor, constant: top.spacing)
        } else {
            mediaView.topAnchor.constraint(equalTo: textLabel.firstBaselineAnchor, constant: -PostBodyView.textTopInset(of: text))
        }
        // 本文のラベルの縮みにくさ（`.defaultHigh`）より低くする。同じだと、ラベルを縮めてサムネイルの高さで本文を切ってしまう。
        let collapse = besideGuide.heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        // 一辺は、入りきらなければ縮められるよう、上限より弱くする。
        let width = mediaView.widthAnchor.constraint(equalToConstant: side)
        width.priority = .required - 1
        var constraints = [
            mediaTop,
            mediaView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            width,
            mediaView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5, constant: -padding - spacing),
            mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor),
            besideGuide.topAnchor.constraint(equalTo: mediaView.topAnchor),
            collapse,
            besideGuide.bottomAnchor.constraint(greaterThanOrEqualTo: mediaView.bottomAnchor),
        ]
        if !textLabel.isHidden {
            constraints += [
                textLabel.trailingAnchor.constraint(equalTo: mediaView.leadingAnchor, constant: -spacing),
                besideGuide.bottomAnchor.constraint(greaterThanOrEqualTo: textLabel.bottomAnchor),
            ]
        }
        return constraints
    }

    private func horizontalConstraints(of view: UIView, padding: CGFloat) -> [NSLayoutConstraint] {
        [
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
        ]
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .systemFill : nil }
    }

    /// 囲みを押せないときは、押せる部品の外の押下を受けず、行に渡す。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self && content?.isPressable == false ? nil : view
    }

    /// 読み上げでは、作者、注意書き、本文を1つの要素として読み、囲みを開く、プロフィール、注意書きの開閉、リンクを、その要素の操作にする。
    /// サムネイルと押せる補足の行は、別の要素のまま残す。
    private func updateAccessibility(for content: Content) {
        let isCollapsed = content.spoiler?.isCollapsed ?? false
        var parts = [content.header?.name.string]
        if let spoiler = content.spoiler {
            parts += [spoiler.kind == .contentWarning ? "注意書き" : nil, spoiler.text.string]
        }
        if !isCollapsed {
            parts.append(content.text.string)
            parts += content.notes.filter { !$0.isPressable }.map(\.text.string)
        }
        summaryElement.accessibilityLabel = parts.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "、")
        var actions: [UIAccessibilityCustomAction] = []
        if content.isPressable {
            actions.append(UIAccessibilityCustomAction(name: content.openActionName) { [weak self] _ in
                self?.sendActions(for: .primaryActionTriggered)
                return true
            })
        }
        if let header = content.header, header.opensAccount {
            actions.append(UIAccessibilityCustomAction(name: "\(header.name.string)のプロフィール") { [weak self] _ in
                self?.openAccount()
                return true
            })
        }
        if let spoiler = content.spoiler {
            actions.append(UIAccessibilityCustomAction(name: SpoilerView.toggleTitle(isCollapsed: spoiler.isCollapsed, kind: spoiler.kind)) { [weak self] _ in
                self?.onToggleSpoiler?()
                return true
            })
        }
        if !isCollapsed {
            actions += LinkLabel.links(in: content.text).map { text, destination in
                UIAccessibilityCustomAction(name: text) { [weak self] _ in
                    self?.onOpenLink?(destination)
                    return true
                }
            }
        }
        summaryElement.accessibilityCustomActions = actions
        setNeedsLayout()
        accessibilityElements = [summaryElement] + [mediaGrid].compactMap(\.self) + noteViews.filter { !$0.isHidden && $0.isUserInteractionEnabled }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        summaryElement.accessibilityFrameInContainerSpace = bounds
    }

    /// 「投稿の見た目」のプレビューで、部品の場所を示すための枠。`space`の座標で返す。
    func previewFrames(in space: UIView) -> AppearancePreviewFrames {
        var frames: AppearancePreviewFrames = [
            .xPost: previewFrame(in: space),
            .xPostAvatar: avatarView.isHidden ? nil : avatarView.previewFrame(in: space),
            // 作者の行のラベルは余った幅を受け持つので、文字のある幅だけを示す。
            .xPostName: nameLabel.isHidden ? nil : nameLabel.previewFrame(in: space)?.map { CGRect(x: $0.minX, y: $0.minY, width: min($0.width, ceil(nameLabel.intrinsicContentSize.width)), height: $0.height) },
            .xPostBody: textLabel.isHidden ? nil : textLabel.previewFrame(in: space),
        ].compactMapValues(\.self)
        // 本文の右に重ねたサムネイルには、本文とのあいだが横のすき間として効くので、別の部品として示す。
        if let grid = mediaGrid {
            frames[grid.content?.isStacked == true ? .xPostBesideMedia : .xPostMedia] = grid.previewFrame(in: space)
        }
        if content?.header != nil {
            frames[.xPostHeader] = [convert(headerGuide.layoutFrame, to: space)]
        }
        if let box = previewFrame(in: space)?.first {
            frames[.xPostPaddingBands] = AppearanceHighlight.paddingBands(of: box, padding: content?.padding ?? 0)
        }
        return frames
    }

    private func updateBorderColor() {
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    }
}

/// 囲みの補足の1行。押せる行は、押下を受けて薄くなる。押せない行は押下を囲みに渡す。
private final class NoteRow: UIControl {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ note: EmbeddedPostView.Content.Note) {
        label.attributedText = note.text
        isUserInteractionEnabled = note.isPressable
        // 先頭の記号は画像の文字なので、読み上げでは除く。
        accessibilityLabel = note.text.string.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFC}").union(.whitespaces))
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }
}
