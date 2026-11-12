import SciaCore
import TextKit2Label
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

        /// 本文の自動翻訳の状態と、原文と訳文を置き換える動きの値。決まりはdocs/auto-translation.mdの「見せ方」にある。
        struct Translation: Equatable {
            /// 本文が訳文。falseなら、訳文を待っている原文。
            var isTranslated: Bool
            var wipeDuration: TimeInterval
            var shiftDuration: TimeInterval
            var wordDuration: TimeInterval
            var fadeWidth: Double
        }

        /// 中身を見分ける。リンクカードから替わったのが同じ囲みかを比べるのに使う。
        var id: String
        var header: Header?
        var avatarSize: CGFloat
        /// 注意書きかフィルターの警告。折りたたんでいる間は、本文、添付ファイル、補足の行を出さない。
        var spoiler: SpoilerView.Content?
        var text: NSAttributedString
        /// 本文が訳文か、訳文を待っているなら、その状態。`text`の先頭の空き（`RichTextRenderer.marksTranslation`）に、翻訳のマークを重ねる。
        var translation: Translation?
        /// 長い本文を切って「続きを読む」を出す行数。nilなら切らない。
        var truncation: BodyTruncation?
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
    /// 切った本文の「続きを読む」が押されたときに呼ぶ。広げた状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onExpandBody: (() -> Void)?

    private let avatarView: AvatarView
    private let nameLabel = EmojiLabel()
    private let spoilerView = SpoilerView()
    private let textLabel = LinkLabel()
    /// 本文の先頭の空きに重ねる、翻訳のマーク。
    private let translationMark = TranslationMarkView()
    /// 本文の1行目のベースライン。TextKit 2で描くラベルのベースラインは、UILabelのベースライン（`firstBaselineAnchor`）ではなく、TextKit 2の並びから置く。
    private let textFirstBaselineGuide = UILayoutGuide()
    private lazy var textFirstBaseline = textFirstBaselineGuide.topAnchor.constraint(equalTo: textLabel.topAnchor)
    /// 本文の1行目の字面の上端。本文の右に出すサムネイルの上端を合わせる。
    /// 1行目のベースラインからの距離（`PostBodyView.textTopInset`）は、行より広いカスタム絵文字を縮めて置くと並べる幅で変わるので、ベースラインと一緒に決め直す。
    private let textGlyphsTopGuide = UILayoutGuide()
    private lazy var textGlyphsTop = textFirstBaselineGuide.topAnchor.constraint(equalTo: textGlyphsTopGuide.topAnchor)
    /// 並べたあとに、本文の字面の上端が変わって高さが変わりうるときに呼ぶ。置く側は、タイムラインの行に高さを測り直させる。
    var onHeightChange: (() -> Void)?
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

    /// 本文のリンクのタップで、タップと長押しの設定によらず、いつも開く（`LinkLabel.opensLinksOnTapOnly`）。
    var opensLinksOnTapOnly: Bool {
        get { textLabel.opensLinksOnTapOnly }
        set { textLabel.opensLinksOnTapOnly = newValue }
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
        // 投稿の本文と同じくTextKit 2で描き、大きくした絵文字の行を絵の高さにする。文字列を入れる前に切り替える。
        textLabel.drawsWithTextKit = true
        textLabel.numberOfLines = 0
        // 本文はリンクの上だけ押下を受ける。リンクの外の押下は、囲みのボタンが受ける。
        textLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
        textLabel.onExpand = { [weak self] in self?.onExpandBody?() }
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))
        accountInteraction = ObjectInteraction(on: avatarView, tapsSelf: false, lift: .shape)
        spoilerView.addAction(UIAction { [weak self] _ in self?.onToggleSpoiler?() }, for: .touchUpInside)
        for view in [avatarView, nameLabel, spoilerView, textLabel, mediaView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(translationMark)
        addLayoutGuide(headerGuide)
        addLayoutGuide(besideGuide)
        addLayoutGuide(textFirstBaselineGuide)
        addLayoutGuide(textGlyphsTopGuide)
        NSLayoutConstraint.activate([
            textFirstBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
            textFirstBaseline,
            textGlyphsTopGuide.heightAnchor.constraint(equalToConstant: 0),
            textGlyphsTop,
        ])
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
        let previous = self.content
        self.content = content
        let previousTranslation = previous?.id == content.id ? previous?.translation : nil
        // 原文と訳文を置き換える動きの値。置き換えなければnil。
        let replacement = previous?.id == content.id && (previousTranslation?.isTranslated ?? false) != (content.translation?.isTranslated ?? false)
            ? content.translation ?? previousTranslation : nil
        // 使い回されて別の囲みに替わったら、前の囲みの置き換えの動きを残さない。
        if previous?.id != content.id {
            textLabel.cancelTextReplacement()
            cancelShiftBelowText()
        }
        // 制約を外すと部品の位置が崩れうるので、その前に今の位置を覚える。
        if let replacement {
            prepareShiftBelowText(duration: replacement.shiftDuration)
        }
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

        if let replacement {
            textLabel.prepareTextReplacement(duration: replacement.wipeDuration, shiftDuration: replacement.shiftDuration, wordDuration: replacement.wordDuration, fadeWidth: replacement.fadeWidth)
        }
        textLabel.attributedText = content.text
        textLabel.truncation = content.truncation
        textLabel.isHidden = isCollapsed || content.text.length == 0
        let pulses: Bool? = textLabel.isHidden || !content.text.hasTranslationMark ? nil : content.translation.map { !$0.isTranslated }
        translationMark.apply(pulses: pulses, keepsPulse: previousTranslation?.isTranslated == false)
        setNeedsLayout()
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
            constraints += applyBesideMedia(media, side: besideSide, spacing: content.mediaSpacing, padding: padding, top: contentTop)
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
        updateTextFirstBaseline()
        variableConstraints = constraints
        NSLayoutConstraint.activate(constraints)
        updateAccessibility(for: content)
    }

    /// 添付ファイルを本文の右に、一辺`side`の正方形で出し、本文はその左に`spacing`をあけて折り返す。上端は本文の1行目の字面の上端にそろえ、本文がなければ本文のラベルの上端に置く。
    /// 囲みは投稿の本文より狭いので、サムネイルとすき間は囲みの内側の半分までに縮め、本文の幅を残す。
    /// `besideGuide`の下端を、本文のラベルとサムネイルの下端のうち、下にあるほうに合わせる。
    private func applyBesideMedia(_ media: MediaGridView.Content, side: CGFloat, spacing: CGFloat, padding: CGFloat, top: (anchor: NSLayoutYAxisAnchor, spacing: CGFloat)) -> [NSLayoutConstraint] {
        mediaView.isHidden = false
        mediaView.apply(media)
        let mediaTop = if textLabel.isHidden {
            mediaView.topAnchor.constraint(equalTo: top.anchor, constant: top.spacing)
        } else {
            mediaView.topAnchor.constraint(equalTo: textGlyphsTopGuide.topAnchor)
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

    /// 本文を今の幅で並べた結果から、1行目のベースラインをラベルの上端からの距離で、1行目の字面の上端をベースラインからの距離で決める。
    /// 中身を適用するときは、まだ本文の幅が決まっていないことがあるので、十分に広い幅で決め、並べたあとに本文の幅で決め直す。
    private func updateTextFirstBaseline() {
        let width = textLabel.bounds.width > 0 ? textLabel.bounds.width : Self.unknownTextWidth
        // UILabelのベースラインと同じく画素にそろえる。そろえないと、ここから置くサムネイルの上下の端が別々に丸められ、正方形の高さが幅と1画素ずれる。
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        let first = (textLabel.textKitBaselines(width: width).first * scale).rounded() / scale
        if textFirstBaseline.constant != first {
            textFirstBaseline.constant = first
        }
        let top = content.map { PostBodyView.textTopInset(of: $0.text, width: width, firstLine: textLabel.textKitLineRanges(of: $0.text, width: width)?.first) } ?? 0
        if textGlyphsTop.constant != top {
            textGlyphsTop.constant = top
        }
    }

    /// 本文の幅が決まる前に、ベースラインを決めるために並べる幅。
    private static let unknownTextWidth: CGFloat = 10_000

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
            parts.append(content.text.stringWithoutTranslationMark)
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
        if !textLabel.isHidden, textLabel.isTruncatedByLength {
            actions.append(UIAccessibilityCustomAction(name: ReadMoreButton.title) { [weak self] _ in
                self?.onExpandBody?()
                return true
            })
        }
        // 本文を切っているかは並べるまで分からないので、並べたあとに変わったら作り直す（`layoutSubviews`）。
        accessibilityReflectsTruncation = !textLabel.isHidden && textLabel.isTruncatedByLength
        summaryElement.accessibilityCustomActions = actions
        setNeedsLayout()
        accessibilityElements = [summaryElement] + [mediaGrid].compactMap(\.self) + noteViews.filter { !$0.isHidden && $0.isUserInteractionEnabled }
    }

    /// 読み上げの要素を作ったときに、本文を切っていたか。
    private var accessibilityReflectsTruncation = false

    override func layoutSubviews() {
        super.layoutSubviews()
        // 本文の幅が決まってから、その幅で1行目のベースラインを決め直す。変わったら、サムネイルを置き直す。
        let baseline = textFirstBaseline.constant
        let glyphsTop = textGlyphsTop.constant
        updateTextFirstBaseline()
        if textFirstBaseline.constant != baseline || textGlyphsTop.constant != glyphsTop {
            super.layoutSubviews()
        }
        // 字面の上端は、行より広いカスタム絵文字の縮め方で変わる。サムネイルが本文より下へ伸びていれば、囲みの高さも変わる。
        if textGlyphsTop.constant != glyphsTop {
            onHeightChange?()
        }
        if let content, !textLabel.isHidden && textLabel.isTruncatedByLength != accessibilityReflectsTruncation {
            updateAccessibility(for: content)
        }
        summaryElement.accessibilityFrameInContainerSpace = bounds
        translationMark.layout(over: textLabel, in: self)
        startPendingShiftBelowText()
    }

    /// 本文を入れ替える前の、本文より下の部品の位置と囲みの高さ。次に並べたときに、そこから新しい位置と高さへ動かす。
    private var pendingShiftBelowText: (views: [(UIView, CGFloat)], height: CGFloat, duration: TimeInterval)?

    private func prepareShiftBelowText(duration: TimeInterval) {
        guard window != nil, duration > 0, !UIAccessibility.isReduceMotionEnabled, !textLabel.isHidden else { return }
        let below = subviews.filter { $0 !== textLabel && $0 !== translationMark && !$0.isHidden && $0.frame.minY >= textLabel.frame.maxY - 1 }
        pendingShiftBelowText = (below.map { ($0, $0.frame.minY) }, bounds.height, duration)
        setNeedsLayout()
    }

    /// 置き換えの動きに付けるキーの先頭。動きの途中にまた置き換わったら、前の動きに足し合わせるので、キーは動きごとに変える。
    private static let shiftKeyPrefix = "textReplacementShift"
    private var shiftCount = 0

    private func addShift(_ animation: CAAnimation, to layer: CALayer) {
        shiftCount += 1
        layer.add(animation, forKey: "\(Self.shiftKeyPrefix)\(shiftCount)")
    }

    private func cancelShiftBelowText() {
        pendingShiftBelowText = nil
        for layer in [layer] + subviews.map(\.layer) {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.shiftKeyPrefix) {
                layer.removeAnimation(forKey: key)
            }
        }
    }

    /// 本文より下の部品と囲みの下端を、前の位置から今の位置へ動かす。本文の段落の文字と、囲みより下の部品と、同じスプリングで動かす。
    private func startPendingShiftBelowText() {
        guard let (views, oldHeight, duration) = pendingShiftBelowText else { return }
        pendingShiftBelowText = nil
        for (view, oldMinY) in views {
            let shift = view.frame.minY - oldMinY
            guard !view.isHidden, abs(shift) > 0.5 else { continue }
            let move = CASpringAnimation.rowSpring(keyPath: "position", duration: duration)
            move.isAdditive = true
            move.fromValue = CGPoint(x: 0, y: -shift)
            move.toValue = CGPoint.zero
            addShift(move, to: view.layer)
        }
        let growth = bounds.height - oldHeight
        guard abs(growth) > 0.5 else { return }
        // 囲みは上端を保ったまま伸び縮みするので、高さと、高さの半分だけ動く中心を一緒に動かす。
        let resize = CASpringAnimation.rowSpring(keyPath: "bounds.size.height", duration: duration)
        resize.isAdditive = true
        resize.fromValue = -growth
        resize.toValue = 0
        addShift(resize, to: layer)
        let move = CASpringAnimation.rowSpring(keyPath: "position.y", duration: duration)
        move.isAdditive = true
        move.fromValue = -growth / 2
        move.toValue = 0
        addShift(move, to: layer)
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
