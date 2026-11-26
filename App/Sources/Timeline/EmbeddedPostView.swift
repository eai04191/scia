import SciaCore
import TextKit2Label
import UIKit

/// 投稿の本文の下に置く、ほかの投稿のカード。Mastodonの引用と、fxtwitterから読んだXの投稿に使う。決まりは`docs/quote.md`と`docs/link-card.md`。
///
/// 上から、作者の行、注意書き、本文、添付ファイル、補足の行を並べる。引用元を出せないときは、作者の行を出さず、理由の1行だけを本文として出す。
/// 添付ファイルを重ねて出すときは、本文の右に置き、本文はその分をあけて折り返す。補足の行は、本文とサムネイルのどちらよりも下に置く。決まりは`docs/timeline-media.md`。
/// カードのどこかが選択されたら、置く側が決めた先を開く。アイコン、注意書き、サムネイル、本文のリンク、選択できる補足の行の押下は、並べた部品が受ける。
final class EmbeddedPostView: UIButton {
    struct Content: Equatable {
        /// 作者の行。出せない理由だけを出すときはnil。
        struct Header: Equatable {
            var avatar: AvatarView.Content
            /// 作者の行の文字。名前は太く、`@`から始まる名前は控えめに描く。
            var name: NSAttributedString
            /// アイコンを選択してプロフィールを開けるか。
            var opensAccount: Bool
        }

        /// 本文と添付ファイルの下に並べる1行。引用元の投票や、引用元がさらに引用していることを示す。
        struct Note: Equatable {
            var text: NSAttributedString
            /// 選択できる見た目にし、押下をカードに渡さず受ける。
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

        /// 中身を見分ける。リンクカードから替わったのが同じカードかを比べるのに使う。
        var id: String
        var header: Header?
        var avatarSize: CGFloat
        /// フィルターの警告。折りたたんでいる間は、注意書き、本文、添付ファイル、補足の行を出さない。
        var filterWarning: SpoilerView.Content?
        /// 注意書き。折りたたんでいる間は、本文、添付ファイル、補足の行を出さない。
        var spoiler: SpoilerView.Content?
        /// 出す注意書き。警告で折りたたんでいる間は出さない。
        var shownSpoiler: SpoilerView.Content? {
            filterWarning?.isCollapsed == true ? nil : spoiler
        }
        /// 警告か注意書きで、本文から下を折りたたんでいる。
        var isCollapsed: Bool {
            filterWarning?.isCollapsed == true || spoiler?.isCollapsed == true
        }
        var text: NSAttributedString
        /// 本文が訳文か、訳文を待っているなら、その状態。`text`の先頭の空き（`RichTextRenderer.marksTranslation`）に、翻訳のマークを重ねる。
        var translation: Translation?
        /// 長い本文を切って「続きを読む」を出す行数。nilなら切らない。
        var truncation: BodyTruncation?
        /// 切った本文の末尾に「続きを読む」を出す。
        var showsReadMore = true
        /// 添付ファイルがなければnil。
        var media: MediaGridView.Content?
        var notes: [Note] = []
        /// カードを選択して開けるか。開けなければ押下を受けず、行に渡す。
        var isPressable = true
        /// 読み上げで、カードを選択する操作の名前。
        var openActionName: String
        /// カードの内側の余白。
        var padding: CGFloat
        /// 作者のアイコンと名前のgap。
        var avatarNameSpacing: CGFloat
        /// 作者の行と本文のあいだ。
        var headerSpacing: CGFloat
        /// 本文、添付ファイル、補足の行のあいだ。
        var mediaSpacing: CGFloat
        /// リンクカードから替わったときに、カードをフェードインさせる時間。
        var transitionDuration: TimeInterval
    }

    /// サムネイルがタップされたときに、何番目の添付ファイルかと、並べているビューを渡して呼ぶ。
    var onSelectMedia: ((Int, MediaGridView) -> Void)?
    /// 閲覧注意のぼかしが選択されたときに呼ぶ。
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
    /// 注意書きかフィルターの警告が選択されたときに、選択したボックスの種類を渡して呼ぶ。開閉した状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onToggleSpoiler: ((PostBodyContent.Spoiler.Kind) -> Void)?
    /// 選択できる補足の行がタップされたときに、何番目の行かを渡して呼ぶ。
    var onSelectNote: ((Int) -> Void)?
    /// 切った本文の「続きを読む」が選択されたときに呼ぶ。広げた状態を持つのは置く側で、適用し直すまで見た目は変わらない。
    var onExpandBody: (() -> Void)?

    private let avatarView: AvatarView
    private let nameLabel = EmojiLabel()
    private let filterWarningView = SpoilerView()
    private let spoilerView = SpoilerView()
    private let textLabel = LinkLabel()
    /// 本文の先頭の空きに重ねる、翻訳のマーク。
    private let translationMark = TranslationMarkView()
    /// 本文の1行目のベースライン。TextKit 2で描くラベルのベースラインは、UILabelのベースライン（`firstBaselineAnchor`）ではなく、TextKit 2の並びから置く。
    private let textFirstBaselineGuide = UILayoutGuide()
    private lazy var textFirstBaseline = textFirstBaselineGuide.topAnchor.constraint(equalTo: textLabel.topAnchor)
    private let textLastBaselineGuide = UILayoutGuide()
    private lazy var textLastBaseline = textLastBaselineGuide.topAnchor.constraint(equalTo: textLabel.bottomAnchor)
    /// 本文の最初の文字の字面の上端と、最後の文字の字面の下端。本文の上下の部品は、投稿の本文と同じく、ここからgapを取って置く。
    /// ベースラインからの距離（`GlyphMetrics.textTopInset`、`textBottomInset`）は、行より広いカスタム絵文字を縮めて置くと並べる幅で変わるので、ベースラインと一緒に決め直す。
    private let textGlyphsTopGuide = UILayoutGuide()
    private let textGlyphsBottomGuide = UILayoutGuide()
    private lazy var textGlyphsTop = textFirstBaselineGuide.topAnchor.constraint(equalTo: textGlyphsTopGuide.topAnchor)
    private lazy var textGlyphsBottom = textGlyphsBottomGuide.topAnchor.constraint(equalTo: textLastBaselineGuide.topAnchor)
    private lazy var nameBaselines = LabelBaselineGuides(of: nameLabel, in: self)
    /// 並べたあとに、本文の字面の上端が変わって高さが変わりうるときに呼ぶ。置く側は、タイムラインの行に高さを測り直させる。
    var onHeightChange: (() -> Void)?
    private let mediaView: MediaGridView
    private var noteViews: [NoteRow] = []
    /// アイコンと名前を並べる作者の行。
    private let headerGuide = UILayoutGuide()
    /// 添付ファイルを本文の右に出すとき、本文とサムネイルの下端のうち、下にあるほう。補足の行をここから並べる。
    private let besideGuide = UILayoutGuide()
    /// 本文の右に出すサムネイルの一辺の制約と、設定の一辺、カードの幅の半分から引く長さ。
    /// カードの幅の半分までに縮めた一辺は画素の途中の長さになり、上下と左右の端が別々に丸められて正方形が1画素ずれるので、並べたあとに画素に切り下げて一辺に入れる。
    private var besideSide: (constraint: NSLayoutConstraint, side: CGFloat, inset: CGFloat)?
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
        // 読み上げでは、カードそのものではなく、まとめた要素とサムネイル、選択できる補足の行を読む。
        isAccessibilityElement = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isUserInteractionEnabled = false
        // 投稿の本文と同じくTextKit 2で描き、大きくした絵文字の行を絵の高さにする。文字列を入れる前に切り替える。
        textLabel.drawsWithTextKit = true
        textLabel.numberOfLines = 0
        // 本文はリンクの上だけ押下を受ける。リンクの外の押下は、カードのボタンが受ける。
        textLabel.onTapLink = { [weak self] destination in self?.onOpenLink?(destination) }
        textLabel.onExpand = { [weak self] in self?.onExpandBody?() }
        avatarView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(avatarTapped)))
        accountInteraction = ObjectInteraction(on: avatarView, tapsSelf: false, lift: .shape)
        filterWarningView.addAction(UIAction { [weak self] _ in self?.onToggleSpoiler?(.filter) }, for: .touchUpInside)
        spoilerView.addAction(UIAction { [weak self] _ in self?.onToggleSpoiler?(.contentWarning) }, for: .touchUpInside)
        for view in [avatarView, nameLabel, filterWarningView, spoilerView, textLabel, mediaView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(translationMark)
        _ = nameBaselines
        addLayoutGuide(headerGuide)
        addLayoutGuide(besideGuide)
        for guide in [textFirstBaselineGuide, textLastBaselineGuide, textGlyphsTopGuide, textGlyphsBottomGuide] {
            addLayoutGuide(guide)
        }
        NSLayoutConstraint.activate([
            textFirstBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
            textFirstBaseline,
            textLastBaselineGuide.heightAnchor.constraint(equalToConstant: 0),
            textLastBaseline,
            textGlyphsTopGuide.heightAnchor.constraint(equalToConstant: 0),
            textGlyphsTop,
            textGlyphsBottomGuide.heightAnchor.constraint(equalToConstant: 0),
            textGlyphsBottom,
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
        // 使い回されて別のカードに替わったら、前のカードの置き換えの動きを残さない。
        if previous?.id != content.id {
            textLabel.cancelTextReplacement()
            cancelShiftBelowText()
        }
        // 制約を外すと部品の位置が崩れうるので、その前に今の位置を覚える。
        if let replacement {
            prepareShiftBelowText(duration: replacement.shiftDuration)
        }
        NSLayoutConstraint.deactivate(variableConstraints)
        besideSide = nil
        let padding = content.padding
        var constraints: [NSLayoutConstraint] = []
        // 次の部品を置く位置。部品を置くたびに下へ進める。文字で終わる部品は、ベースラインから字面の下端までを`inset`に持つ。
        var last: (anchor: NSLayoutYAxisAnchor, inset: CGFloat, spacing: CGFloat) = (topAnchor, 0, padding)

        if let header = content.header {
            avatarView.isHidden = false
            nameLabel.isHidden = false
            avatarView.apply(header.avatar)
            avatarView.isUserInteractionEnabled = header.opensAccount
            nameLabel.attributedText = header.name
            // 作者の行の高さは、アイコンと名前の字面の高いほう。アイコンと名前の字面を、行の上下中央に揃える。
            let nameTop = nameLabel.glyphsTopInset
            let nameBottom = nameLabel.glyphsBottomInset
            let compactHeader = headerGuide.heightAnchor.constraint(equalToConstant: 0)
            // 下限だけでは高さが決まらないため、収まる最小の高さに寄せる。
            compactHeader.priority = .defaultLow
            constraints += [
                headerGuide.topAnchor.constraint(equalTo: last.anchor, constant: last.inset + last.spacing),
                headerGuide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                headerGuide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
                headerGuide.heightAnchor.constraint(greaterThanOrEqualToConstant: content.avatarSize),
                compactHeader,
                nameLabel.firstBaselineAnchor.constraint(greaterThanOrEqualTo: headerGuide.topAnchor, constant: nameTop),
                headerGuide.bottomAnchor.constraint(greaterThanOrEqualTo: nameLabel.lastBaselineAnchor, constant: nameBottom),
                avatarView.leadingAnchor.constraint(equalTo: headerGuide.leadingAnchor),
                avatarView.centerYAnchor.constraint(equalTo: headerGuide.centerYAnchor),
                avatarView.widthAnchor.constraint(equalToConstant: content.avatarSize),
                avatarView.heightAnchor.constraint(equalToConstant: content.avatarSize),
                nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: content.avatarNameSpacing),
                nameLabel.trailingAnchor.constraint(equalTo: headerGuide.trailingAnchor),
                nameLabel.firstBaselineAnchor.constraint(equalTo: headerGuide.centerYAnchor, constant: (nameTop - nameBottom) / 2),
            ]
            last = (headerGuide.bottomAnchor, 0, content.headerSpacing)
        } else {
            avatarView.isHidden = true
            nameLabel.isHidden = true
        }

        for (view, box) in [(filterWarningView, content.filterWarning), (spoilerView, content.shownSpoiler)] {
            guard let box else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            view.apply(box)
            constraints += horizontalConstraints(of: view, padding: padding)
            constraints.append(view.topAnchor.constraint(equalTo: last.anchor, constant: last.inset + last.spacing))
            last = (view.bottomAnchor, 0, content.mediaSpacing)
        }
        let isCollapsed = content.isCollapsed
        let media = isCollapsed ? nil : content.media.flatMap { $0.aspectRatio == nil ? nil : $0 }
        let besideSide: CGFloat? = if case .stack(let side)? = media?.arrangement { side } else { nil }
        // 本文と、本文の右に出すサムネイルの上端。本文がなくても、サムネイルは本文があるときの位置に置く。
        let contentTop = last

        if let replacement {
            textLabel.prepareTextReplacement(duration: replacement.wipeDuration, shiftDuration: replacement.shiftDuration, wordDuration: replacement.wordDuration, fadeWidth: replacement.fadeWidth)
        }
        textLabel.attributedText = content.text
        textLabel.truncation = content.truncation
        textLabel.showsReadMore = content.showsReadMore
        textLabel.isHidden = isCollapsed || content.text.length == 0
        let pulses: Bool? = textLabel.isHidden || !content.text.hasTranslationMark ? nil : content.translation.map { !$0.isTranslated }
        translationMark.apply(pulses: pulses, keepsPulse: previousTranslation?.isTranslated == false)
        setNeedsLayout()
        if !textLabel.isHidden {
            constraints += [
                textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                textGlyphsTopGuide.topAnchor.constraint(equalTo: last.anchor, constant: last.inset + last.spacing),
            ]
            // 本文の右にサムネイルを出すときの右端は、サムネイルの左に合わせる。
            if besideSide == nil {
                constraints.append(textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding))
            }
            last = (textGlyphsBottomGuide.topAnchor, 0, content.mediaSpacing)
        }

        if let media, let besideSide {
            constraints += applyBesideMedia(media, side: besideSide, spacing: content.mediaSpacing, padding: padding, top: contentTop)
            last = (besideGuide.bottomAnchor, 0, content.mediaSpacing)
        } else if let media, let aspectRatio = media.aspectRatio {
            mediaView.isHidden = false
            mediaView.apply(media)
            constraints += horizontalConstraints(of: mediaView, padding: padding)
            constraints += [
                mediaView.topAnchor.constraint(equalTo: last.anchor, constant: last.inset + last.spacing),
                mediaView.heightAnchor.constraint(equalTo: mediaView.widthAnchor, multiplier: 1 / aspectRatio),
            ]
            last = (mediaView.bottomAnchor, 0, content.mediaSpacing)
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
            constraints.append(row.firstBaselineAnchor.constraint(equalTo: last.anchor, constant: last.inset + last.spacing + row.glyphsInsets.top))
            last = (row.lastBaselineAnchor, row.glyphsInsets.bottom, content.mediaSpacing)
        }

        constraints.append(bottomAnchor.constraint(equalTo: last.anchor, constant: last.inset + padding))
        updateTextBaselines()
        variableConstraints = constraints
        NSLayoutConstraint.activate(constraints)
        updateAccessibility(for: content)
    }

    /// 添付ファイルを本文の右に、一辺`side`の正方形で出し、本文はその左に`spacing`をあけて折り返す。上端は本文の1行目の字面の上端にそろえ、本文がなければ本文の字面の上端があるはずの位置に置く。
    /// カードは投稿の本文より狭いので、サムネイルとgapはカードの内側の半分までに縮め、本文の幅を残す。
    /// `besideGuide`の下端を、本文の字面とサムネイルの下端のうち、下にあるほうに合わせる。
    private func applyBesideMedia(_ media: MediaGridView.Content, side: CGFloat, spacing: CGFloat, padding: CGFloat, top: (anchor: NSLayoutYAxisAnchor, inset: CGFloat, spacing: CGFloat)) -> [NSLayoutConstraint] {
        mediaView.isHidden = false
        mediaView.apply(media)
        let mediaTop = if textLabel.isHidden {
            mediaView.topAnchor.constraint(equalTo: top.anchor, constant: top.inset + top.spacing)
        } else {
            mediaView.topAnchor.constraint(equalTo: textGlyphsTopGuide.topAnchor)
        }
        // 本文のラベルの縮みにくさ（`.defaultHigh`）より低くする。同じだと、ラベルを縮めてサムネイルの高さで本文を切ってしまう。
        let collapse = besideGuide.heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .defaultLow
        // 一辺は、入りきらなければ縮められるよう、上限より弱くする。上限は、並べたあとに画素にそろえて一辺に入れる（`fitBesideSide`）。
        let width = mediaView.widthAnchor.constraint(equalToConstant: side)
        width.priority = .required - 1
        besideSide = (width, side, padding + spacing)
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
                besideGuide.bottomAnchor.constraint(greaterThanOrEqualTo: textGlyphsBottomGuide.topAnchor),
            ]
        }
        return constraints
    }

    /// 本文を今の幅で並べた結果から、最初と最後のベースラインをラベルの上下の端からの距離で、字面の上下の端をベースラインからの距離で決める。
    /// 中身を適用するときは、まだ本文の幅が決まっていないことがあるので、十分に広い幅で決め、並べたあとに本文の幅で決め直す。
    private func updateTextBaselines() {
        let width = textLabel.bounds.width > 0 ? textLabel.bounds.width : Self.unknownTextWidth
        // UILabelのベースラインと同じく画素にそろえる。そろえないと、ここから置くサムネイルの上下の端が別々に丸められ、正方形の高さが幅と1画素ずれる。
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        let baselines = textLabel.textKitBaselines(width: width)
        let first = (baselines.first * scale).rounded() / scale
        if textFirstBaseline.constant != first {
            textFirstBaseline.constant = first
        }
        let last = -(baselines.lastFromBottom * scale).rounded() / scale
        if textLastBaseline.constant != last {
            textLastBaseline.constant = last
        }
        let lines = content.flatMap { textLabel.textKitLineRanges(of: $0.text, width: width) }
        // 字面までの距離も画素にそろえる。字面の上端から置くサムネイルが画素の途中に来ると、同じく正方形の高さが幅と1画素ずれる。
        let top = ((content.map { GlyphMetrics.textTopInset(of: $0.text, width: width, firstLine: lines?.first) } ?? 0) * scale).rounded() / scale
        if textGlyphsTop.constant != top {
            textGlyphsTop.constant = top
        }
        let bottom = ((content.map { GlyphMetrics.textBottomInset(of: $0.text, width: width, lastLine: lines?.last) } ?? 0) * scale).rounded() / scale
        if textGlyphsBottom.constant != bottom {
            textGlyphsBottom.constant = bottom
        }
    }

    /// 本文の右に出すサムネイルの一辺を、設定の一辺とカードの幅の半分までのうち短いほうを画素に切り下げた長さにする。
    /// - Returns: 一辺が変わったか。
    private func fitBesideSide() -> Bool {
        guard let besideSide, bounds.width > 0 else { return false }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        let side = (min(besideSide.side, bounds.width / 2 - besideSide.inset) * scale).rounded(.down) / scale
        guard besideSide.constraint.constant != side else { return false }
        besideSide.constraint.constant = side
        return true
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

    /// カードを選択できないときは、選択できる部品の外の押下を受けず、行に渡す。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self && content?.isPressable == false ? nil : view
    }

    /// 読み上げでは、作者、注意書き、本文を1つの要素として読み、カードを開く、プロフィール、注意書きの開閉、リンクを、その要素の操作にする。
    /// サムネイルと選択できる補足の行は、別の要素のまま残す。
    private func updateAccessibility(for content: Content) {
        let isCollapsed = content.isCollapsed
        let boxes = [content.filterWarning, content.shownSpoiler].compactMap(\.self)
        var parts = [content.header?.name.string]
        for box in boxes {
            parts += [box.kind == .contentWarning ? PostTexts.contentWarningLabel : nil, box.text.stringSpeakingListSeparators]
        }
        if !isCollapsed {
            parts.append(content.text.stringWithoutTranslationMark)
            parts += content.notes.filter { !$0.isPressable }.map(\.text.string)
        }
        summaryElement.accessibilityLabel = parts.compactMap(\.self).filter { !$0.isEmpty }.joinedAsTextList
        var actions: [UIAccessibilityCustomAction] = []
        if content.isPressable {
            actions.append(UIAccessibilityCustomAction(name: content.openActionName) { [weak self] _ in
                self?.sendActions(for: .primaryActionTriggered)
                return true
            })
        }
        if let header = content.header, header.opensAccount {
            actions.append(UIAccessibilityCustomAction(name: PostTexts.openProfile(name: header.name.string)) { [weak self] _ in
                self?.openAccount()
                return true
            })
        }
        for box in boxes {
            actions.append(UIAccessibilityCustomAction(name: SpoilerView.toggleTitle(isCollapsed: box.isCollapsed, kind: box.kind)) { [weak self] _ in
                self?.onToggleSpoiler?(box.kind)
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
        if !textLabel.isHidden, textLabel.isTruncatedByLength, textLabel.showsReadMore {
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
        // 本文の幅が決まってから、その幅でベースラインと字面の上下の端を決め直す。変わったら、本文の上下の部品を置き直す。
        let before = [textFirstBaseline, textLastBaseline, textGlyphsTop, textGlyphsBottom].map(\.constant)
        updateTextBaselines()
        let after = [textFirstBaseline, textLastBaseline, textGlyphsTop, textGlyphsBottom].map(\.constant)
        let sideChanged = fitBesideSide()
        if after != before || sideChanged {
            super.layoutSubviews()
        }
        // 字面の上下の端は、行より広いカスタム絵文字の縮め方で変わり、カードの高さも変わる。サムネイルの一辺を縮めても変わる。
        if after[2...] != before[2...] || sideChanged {
            onHeightChange?()
        }
        if let content, !textLabel.isHidden && textLabel.isTruncatedByLength != accessibilityReflectsTruncation {
            updateAccessibility(for: content)
        }
        summaryElement.accessibilityFrameInContainerSpace = bounds
        translationMark.layout(over: textLabel, in: self)
        startPendingShiftBelowText()
    }

    /// 本文を入れ替える前の、本文より下の部品の位置とカードの高さ。次に並べたときに、そこから新しい位置と高さへ動かす。
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

    /// 本文より下の部品とカードの下端を、前の位置から今の位置へ動かす。本文の段落の文字と、カードより下の部品と、同じスプリングで動かす。
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
        // カードは上端を保ったまま伸び縮みするので、高さと、高さの半分だけ動く中心を一緒に動かす。
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
            .xPostName: nameGlyphsFrame(in: space),
            .xPostBody: textGlyphsFrame(in: space),
        ].compactMapValues(\.self)
        // 本文の右に重ねたサムネイルには、本文とのあいだが横のgapとして効くので、別の部品として示す。
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

    /// 作者の名前の字面の枠。名前のラベルは余った幅を受け持つので、文字のある幅だけを示す。
    private func nameGlyphsFrame(in space: UIView) -> [CGRect]? {
        nameLabel.isHidden ? nil : nameBaselines.glyphsFrame(in: space, width: ceil(nameLabel.intrinsicContentSize.width))
    }

    /// 本文の字面の枠。上端は最初のベースラインから、下端は最後のベースラインから、em枠で測る。
    private func textGlyphsFrame(in space: UIView) -> [CGRect]? {
        guard let label = textLabel.previewFrame(in: space)?.first else { return nil }
        let top = convert(CGPoint(x: 0, y: textGlyphsTopGuide.layoutFrame.minY), to: space).y
        let bottom = convert(CGPoint(x: 0, y: textGlyphsBottomGuide.layoutFrame.minY), to: space).y
        return [CGRect(x: label.minX, y: top, width: label.width, height: max(bottom - top, 0))]
    }

    private func updateBorderColor() {
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    }
}

/// カードの補足の1行。選択できる行は、押下を受けて薄くなる。選択できない行は押下をカードに渡す。
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

    // カードは、補足の行をベースラインから字面で測って並べる。
    override var forFirstBaselineLayout: UIView { label }
    override var forLastBaselineLayout: UIView { label }

    /// ベースラインから字面の上端と下端まで。
    var glyphsInsets: (top: CGFloat, bottom: CGFloat) { (label.glyphsTopInset, label.glyphsBottomInset) }

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
